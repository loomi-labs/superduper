import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/theme.dart';
import 'package:superduper/utils/logger.dart';

/// The short explanation of what the setup flow is about and why it takes
/// two power cycles.
///
/// Shared between the gate's own intro card ([SetupGateCard] in `bike.dart`)
/// and [SetupStep.intro] here, so the two screens the rider sees back to back
/// — the gate that offers the wizard, then the wizard's own first screen —
/// never say the same thing two different ways.
const setupIntroBody =
    'The app finds out what your bike accepts, and what it forgets when you '
    'switch it off.\n\nPark the bike. You switch it off and on two times. '
    'This takes about two minutes.';

/// The date a capability record was measured, as the settings sheet shows it.
String calibrationDate(DateTime at) => '${at.year}-'
    '${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')}';

/// Joins [items] in prose: `'a'`, `'a and b'`, `'a, b and c'`.
String _joinAnd(List<String> items) {
  if (items.length == 1) {
    return items.first;
  }
  if (items.length == 2) {
    return '${items[0]} and ${items[1]}';
  }
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}

/// The wire's mode label, or the raw byte for a firmware the app does not
/// know — mirrors the old boot-calibration guide's own `_wireName`, but names
/// the mode the way the rest of the app now does: by its label, not its
/// firmware name.
String _wireLabel(int wire, BikeRegion? region) =>
    wire >= 0 && wire < firmwareProfiles.length
        ? profileByWire(wire).label(region)
        : 'mode $wire';

/// What [capabilities] accepts, in the rider's words: everything, or a
/// sentence per control the firmware refuses.
String _acceptedLine(BikeCapabilities capabilities) {
  if (capabilities.modeWritable &&
      capabilities.assistWritable &&
      capabilities.lightWritable) {
    return 'It accepts every mode, every assist level and the light.';
  }
  final sentences = <String>[];
  final accepted = <String>[];
  if (capabilities.modeWritable) {
    accepted.add('every mode');
  }
  if (capabilities.assistWritable) {
    accepted.add('every assist level');
  }
  if (capabilities.lightWritable) {
    accepted.add('the light');
  }
  if (accepted.isNotEmpty) {
    sentences.add('It accepts ${_joinAnd(accepted)}.');
  }
  if (!capabilities.modeWritable) {
    sentences.add('It does not let the app change the mode. The app hides '
        'the mode picker.');
  }
  if (!capabilities.assistWritable) {
    sentences.add('It does not let the app change the assist level. The '
        'app hides the assist picker.');
  }
  if (!capabilities.lightWritable) {
    sentences.add('It does not let the app change the light. The app hides '
        'the light control.');
  }
  return sentences.join(' ');
}

/// What [signature] resets on power-on, in the rider's words, or the honest
/// fallback when nothing measured resets at all.
String _resetLine(BootSignature signature, BikeRegion? region) {
  final wire = signature.bootWire;
  final assist = signature.bootAssist;
  final light = signature.bootLight;
  if (wire == null && assist == null && light == null) {
    return 'Automatic power-cycle detection is not possible on this bike. '
        'Your locks and your startup values still work when you connect it '
        'yourself.';
  }
  final resets = <String>[
    if (wire != null) 'the mode to ${_wireLabel(wire, region)}',
    if (assist != null) 'the assist to $assist',
    if (light != null) 'the light to ${light ? 'on' : 'off'}',
  ];
  return 'It resets ${_joinAnd(resets)} when you switch it on. The app uses '
      'that to see a power cycle.';
}

/// What the app measured, in the rider's words: the detected region (if
/// any), what the bike accepts, and what it resets on power-on. Built from
/// the two records [Bike.saveCapabilities] saves together, so the wizard's
/// `done` step can only ever describe a bike it has actually finished
/// measuring.
String setupSummary(BikeCapabilities capabilities, BootSignature signature,
    {BikeRegion? region}) {
  final detected = capabilities.detectedRegion;
  final lines = <String>[
    if (detected != null)
      'Your bike answers the ${detected.value} modes. Region set to '
          '${detected.value}.',
    _acceptedLine(capabilities),
    _resetLine(signature, region ?? detected),
  ];
  return lines.join('\n\n');
}

/// Where the wizard is. One screen per step, and every one of them before
/// [done] can be left with nothing measured kept.
enum SetupStep {
  /// What the wizard is about to do, with Start and no way to skip it.
  intro,

  /// Waiting for the rider to switch the bike off, the first time.
  turnOff1,

  /// Waiting for the bike to come back, the first time.
  turnOn1,

  /// The first boot read.
  readBoot1,

  /// The capability probe is running.
  probing,

  /// Waiting for the rider to switch the bike off, the second time.
  turnOff2,

  /// Waiting for the bike to come back, the second time.
  turnOn2,

  /// The second boot read.
  readBoot2,

  /// Everything was measured and saved.
  done,

  /// The wizard gave up, with a reason.
  failed,
}

/// Measures what a bike accepts and what it forgets on a power cycle, across
/// two power cycles, and gates the bike's controls until it has run once.
///
/// A pushed page and not a sheet: the flow spans two power cycles of the
/// bike, so it lives for minutes, and a sheet is one stray drag away from
/// being dismissed in the middle of it — which would leave the rider halfway
/// through a power cycle with no result.
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key, required this.bikeID});

  final String bikeID;

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  /// How long a connection-wait step waits before it says the rider may have
  /// to help.
  static const _offHint = Duration(seconds: 30);
  static const _onHint = Duration(seconds: 45);

  var _step = SetupStep.intro;

  /// The extra line a step shows when it has waited long enough to suspect
  /// something went wrong. Never a failure — the rider may just be slow.
  String? _hint;

  String? _failure;

  /// The live readout of [Bike.probeCapabilities]'s sweep, or null before it
  /// starts / when the caller chose not to pass a progress callback's result
  /// on yet.
  ProbeProgress? _progress;

  /// The first boot read, the probe's parting state and the second boot
  /// read — held in LOCAL widget state only, thrown away with the widget on
  /// every exit before [SetupStep.done]. Nothing here reaches
  /// [BikeState.capabilities] or [BikeState.bootSignature] until the very
  /// last step calls [Bike.saveCapabilities] — that is the whole point of
  /// keeping them here rather than saving as each one arrives: a rider who
  /// cancels after the probe succeeds must still see an ungated bike.
  LastSeen? _bootA;
  LastSeen? _parting;
  LastSeen? _bootB;
  BikeCapabilities? _capabilities;
  BootSignature? _signature;

  bool _guardOpen = false;
  bool _cancelled = false;
  bool _finished = false;

  /// Whether the sweep ran to its end — and so left the bike parked on values
  /// of its own — with nothing saved yet.
  ///
  /// [Bike.probeCapabilities] restores the boot values only when it could NOT
  /// finish; a sweep that finished parks the bike on the safe wire, the parting
  /// assist and the flipped light, because the caller normally keeps that
  /// result and power-cycles the bike anyway. Every exit of this flow that
  /// keeps nothing has to undo it instead: with capabilities still null, the
  /// gate hides the very controls the rider would need to put the bike back by
  /// hand. Cleared the moment the result IS saved.
  bool _probeParked = false;

  /// Set by a Cancel tap while [SetupStep.probing] is running. Dart cannot
  /// abort the in-flight [Bike.probeCapabilities] future, and its writes go
  /// straight to the bike below [Bike.setCalibrating]'s suppression — closing
  /// the window right away would reopen the exact write race a previous fix
  /// closed. This only records the rider's intent; [_run] checks it once the
  /// probe returns (successfully or not) and finishes the flow exactly as an
  /// ordinary cancel would, with nothing saved.
  bool _cancelPending = false;

  /// The step's wait for the link to go down or come back, and which of the
  /// two it waits for.
  Completer<bool>? _waiter;
  bool _wantConnected = false;
  Timer? _hintTimer;

  /// Fires a fast, dedicated connect attempt while [_waitForConnection] waits
  /// for the bike to come back on. See [_waitForConnection] for why.
  Timer? _reconnectPollTimer;

  /// Taken once: the wizard has to release the write-suppression window even
  /// while the page is going away, and reading a provider there is too late.
  late final Bike _bike = ref.read(bikeProvider(widget.bikeID).notifier);

  ProviderSubscription<SDBluetoothConnectionState>? _connectionSub;

  /// Whether the flow may still touch the page.
  bool get _alive => mounted && !_cancelled;

  @override
  void initState() {
    super.initState();
    _connectionSub = ref.listenManual(
        connectionHandlerProvider(widget.bikeID), (previous, next) {
      final waiter = _waiter;
      if (waiter == null || waiter.isCompleted) {
        return;
      }
      final connected = next == SDBluetoothConnectionState.connected;
      if (connected == _wantConnected) {
        waiter.complete(true);
      }
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _reconnectPollTimer?.cancel();
    _cancelled = true;
    _waiter = null;
    _connectionSub?.close();
    // A backstop only, and deliberately just the window: the page can be
    // disposed with its whole container, where a write would have nothing to
    // write through.
    _releaseGuard();
    super.dispose();
  }

  /// Closes the write-suppression window. Idempotent, because every exit of
  /// the flow calls it.
  void _releaseGuard() {
    if (!_guardOpen) {
      return;
    }
    _guardOpen = false;
    _bike.setCalibrating(false);
  }

  /// Everything a wizard that did not save anything has to undo: the window,
  /// and the values a completed sweep parked the bike on ([_probeParked]).
  /// Nothing is staged on the bike before the window opens, so there is
  /// nothing else bike-side to put back.
  ///
  /// The restore goes out before the window closes, so no ordinary write can
  /// race it, and it is not awaited: every caller here is already leaving, and
  /// the write is best-effort by contract (see [Bike.restoreAfterProbe]).
  void _finish() {
    if (_finished) {
      return;
    }
    _finished = true;
    final bootA = _bootA;
    if (_probeParked && bootA != null) {
      _probeParked = false;
      unawaited(_bike.restoreAfterProbe(bootA));
    }
    _releaseGuard();
  }

  void _cancel() {
    _cancelled = true;
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(false);
    }
    _finish();
    Navigator.of(context).maybePop();
  }

  /// Cancel while the sweep is running: see [_cancelPending]. Only records
  /// the intent and updates the copy the rider sees; [_run] does the actual
  /// cleanup once the sweep itself returns.
  void _requestCancel() {
    if (_cancelPending) {
      return;
    }
    setState(() {
      _cancelPending = true;
      _hint = 'Finishing the test, then stopping…';
    });
  }

  /// The cleanup for a cancel that arrived during the probe, run once the
  /// probe itself has returned. The same outcome [_cancel] gives at every
  /// other step: the guard released, nothing saved, the page popped.
  void _finishCancelledProbe() {
    if (mounted) {
      _cancel();
    } else {
      // The page is already gone for some other reason; there is nothing
      // left to pop, but the guard still has to close.
      _finish();
    }
  }

  void _fail(String reason) {
    _finish();
    if (!mounted) {
      return;
    }
    setState(() {
      _failure = reason;
      _hint = null;
      _progress = null;
      _step = SetupStep.failed;
    });
  }

  /// Waits for the link to go down ([connected] false) or to come back.
  /// Returns false when the rider cancelled instead.
  Future<bool> _waitForConnection(
      {required bool connected,
      required Duration hintAfter,
      required String hint}) {
    final now = ref.read(connectionHandlerProvider(widget.bikeID)) ==
        SDBluetoothConnectionState.connected;
    if (now == connected) {
      return Future<bool>.value(true);
    }
    _wantConnected = connected;
    final waiter = Completer<bool>();
    _waiter = waiter;
    _hintTimer?.cancel();
    _hintTimer = Timer(hintAfter, () {
      if (mounted) {
        setState(() => _hint = hint);
      }
    });
    if (connected) {
      // The rider is standing at the bike for a bounded couple of minutes,
      // not leaving the app running for hours, so this step asks again on
      // its own fast, fixed cadence — it does not wait for the bike's normal
      // background reconnect ladder, and it does not care whether the rider
      // has Auto-reconnect turned on for this bike.
      _reconnectPollTimer?.cancel();
      ref
          .read(connectionHandlerProvider(widget.bikeID).notifier)
          .connect(timeout: const Duration(seconds: 2));
      _reconnectPollTimer =
          Timer.periodic(const Duration(milliseconds: 1500), (_) {
        ref
            .read(connectionHandlerProvider(widget.bikeID).notifier)
            .connect(timeout: const Duration(seconds: 2));
      });
    }
    return waiter.future.whenComplete(() {
      _hintTimer?.cancel();
      _hintTimer = null;
      _reconnectPollTimer?.cancel();
      _reconnectPollTimer = null;
      _waiter = null;
    });
  }

  static const _offHintText =
      'The bike is still connected. Hold the power button until the bike '
      'is off.';
  static const _onHintText =
      'The app cannot find the bike. Make sure the bike is on and near the '
      'phone, then use Connect.';

  /// [_runSteps], guarded against a step throwing instead of returning a
  /// plain failure sentinel (a real BLE exception rather than a `null`
  /// [Bike.readBikeState]/[Bike.probeCapabilities] already handles on its
  /// own). Left uncaught, such an exception would strand [_step] wherever it
  /// was — typically [SetupStep.probing], mid-spinner, with the calibration
  /// guard held open until the rider force-backs out and [dispose]'s own
  /// backstop finally closes it.
  ///
  /// A cancel tapped during the probe (see [_cancelPending]) takes priority
  /// over reporting the exception as a failure: the rider already asked to
  /// leave, so this finishes the flow the same way a clean cancel would
  /// rather than showing them a failure screen for it.
  Future<void> _run() async {
    try {
      await _runSteps();
    } catch (e, st) {
      log.e(SDLogger.bike, 'Setup wizard step threw', e, st);
      if (_cancelPending) {
        _finishCancelledProbe();
        return;
      }
      _fail('Something went wrong. Try again.');
    }
  }

  /// The whole flow, in the order the rider walks it. Every await is
  /// followed by the same question: is this page still the one the rider is
  /// looking at. Re-entered from the top by both the intro's Start and a
  /// retry after [SetupStep.failed] — a full restart is the only safe choice
  /// once anything has failed: a [_bootA] or [_capabilities] left over from
  /// an earlier, incomplete attempt must never be trusted for a fresh probe
  /// or a fresh second boot.
  Future<void> _runSteps() async {
    _cancelled = false;
    _finished = false;
    _cancelPending = false;
    _probeParked = false;
    _bootA = null;
    _parting = null;
    _bootB = null;
    _capabilities = null;
    _signature = null;
    // Opened right away: unlike the old one-boot guide, nothing is staged on
    // the bike first — this flow simply reads whatever the bike naturally
    // boots into, so there is nothing to write before the window opens.
    _bike.setCalibrating(true);
    _guardOpen = true;
    setState(() {
      _step = SetupStep.turnOff1;
      _hint = null;
      _failure = null;
      _progress = null;
    });
    final off1 = await _waitForConnection(
        connected: false, hintAfter: _offHint, hint: _offHintText);
    if (!off1 || !_alive) {
      return;
    }
    setState(() {
      _step = SetupStep.turnOn1;
      _hint = null;
    });
    final on1 = await _waitForConnection(
        connected: true, hintAfter: _onHint, hint: _onHintText);
    if (!on1 || !_alive) {
      return;
    }
    setState(() {
      _step = SetupStep.readBoot1;
      _hint = null;
    });
    // Let the transport's own post-connect handshake finish first. A real
    // device log caught the race this avoids: right after a reconnect, the
    // transport asks the bike for ride data as part of becoming ready, and
    // that request selects a different register than the read below needs —
    // a read this early can come back with ride data instead of settings and
    // fail outright. See [Bike.connectSettle] and [Bike._reassertAfterReconnect],
    // which waits out the exact same race on the control loop's own reconnect
    // path.
    await Future<void>.delayed(Bike.connectSettle);
    if (!_alive) {
      return;
    }
    final bootA = await _bike.readBikeState();
    if (!_alive) {
      return;
    }
    if (bootA == null) {
      _fail('The app could not read the bike. Make sure it is on, standing '
          'still and in range, then try again.');
      return;
    }
    _bootA = bootA;
    setState(() {
      _step = SetupStep.probing;
      _hint = null;
    });
    // The window stays open through the whole probe, on purpose: closing it
    // here would let the ordinary poll interleave a heal or a startup-pin
    // write with the sweep, racing the probe's own writes on the same
    // register. [Bike.probeCapabilities] writes the bus directly, below
    // writeStateData, so the window does nothing for the probe's own
    // writes — it protects everything else from the probe, not the other
    // way round.
    final capabilities =
        await _bike.probeCapabilities(bootA, onProgress: (progress) {
      if (!mounted) {
        return;
      }
      setState(() => _progress = progress);
    });
    if (capabilities != null) {
      // Recorded before any of the exits below is reached, so every one of
      // them — the cancel just below, a failed read of the parting state, the
      // back gesture, a cancel at either of the two steps that follow — puts
      // the bike back where it booted. See [_probeParked].
      _probeParked = true;
    }
    if (_cancelPending) {
      // The sweep ran to completion regardless of the tap (Dart cannot abort
      // it, and it writes below the calibration guard's own suppression —
      // see _cancelPending). Finish exactly as an ordinary cancel would,
      // whether the sweep succeeded or not: nothing measured here is saved.
      // A completed sweep left the bike parked on values of its own, which
      // _finish puts back — see [_probeParked].
      _finishCancelledProbe();
      return;
    }
    if (!_alive) {
      return;
    }
    if (capabilities == null) {
      _fail('The app could not test the bike. Make sure it is on and '
          'standing still, then try again.');
      return;
    }
    _capabilities = capabilities;
    // The probe's own parting state — what it left on the bus — is not
    // handed back by probeCapabilities itself, so it is captured with one
    // more plain read, right after: the window never closed between the two
    // calls, so nothing else touched the bike in between.
    final parting = await _bike.readBikeState();
    if (!_alive) {
      return;
    }
    if (parting == null) {
      _fail('The app could not read the bike after testing it. Make sure it '
          'is on and in range, then try again.');
      return;
    }
    _parting = parting;
    setState(() {
      _step = SetupStep.turnOff2;
      _hint = null;
      _progress = null;
    });
    final off2 = await _waitForConnection(
        connected: false, hintAfter: _offHint, hint: _offHintText);
    if (!off2 || !_alive) {
      return;
    }
    setState(() {
      _step = SetupStep.turnOn2;
      _hint = null;
    });
    final on2 = await _waitForConnection(
        connected: true, hintAfter: _onHint, hint: _onHintText);
    if (!on2 || !_alive) {
      return;
    }
    setState(() {
      _step = SetupStep.readBoot2;
      _hint = null;
    });
    // Same wait as after the first reconnect above, and for the same reason:
    // the transport's post-connect handshake needs to finish before the read
    // below can trust the register it selects.
    await Future<void>.delayed(Bike.connectSettle);
    if (!_alive) {
      return;
    }
    final bootB = await _bike.readBikeState();
    if (!_alive) {
      return;
    }
    if (bootB == null) {
      _fail('The app could not read the bike. Make sure it is on, standing '
          'still and in range, then try again.');
      return;
    }
    _bootB = bootB;
    // Only now: everything measured is saved in one call, so a rider who
    // quits between two separate saves could never end up with capabilities
    // recorded but no signature, or vice-versa.
    final signature = _bike.saveCapabilities(
        capabilities: _capabilities!, parting: _parting!, bootB: _bootB!);
    // The result is kept, so the parking values are not something to undo: the
    // rider power-cycled the bike after them anyway, and the ordinary control
    // loop takes the bike from here the moment the window closes.
    _probeParked = false;
    _finish();
    if (!mounted) {
      return;
    }
    setState(() {
      _signature = signature;
      _step = SetupStep.done;
    });
  }

  String get _title => switch (_step) {
        SetupStep.intro => 'Set up this bike',
        SetupStep.turnOff1 || SetupStep.turnOff2 => 'Switch the bike off',
        SetupStep.turnOn1 || SetupStep.turnOn2 => 'Switch the bike on',
        SetupStep.readBoot1 || SetupStep.readBoot2 => 'Reading the bike',
        SetupStep.probing => 'Testing the bike',
        SetupStep.done => 'Setup complete',
        SetupStep.failed => 'Setup stopped',
      };

  /// A simple `▓▓▓░░░` readout of [_progress], [width] characters wide.
  String _progressBar(int done, int total, {int width = 10}) {
    final filled = total <= 0 ? 0 : (done / total * width).round().clamp(0, width);
    return '${'▓' * filled}${'░' * (width - filled)}';
  }

  String get _probingBody {
    const base = 'The app tries every mode, every assist level and the '
        'light. Do not touch the bike or the phone.';
    final progress = _progress;
    if (progress == null) {
      return base;
    }
    return '$base\n\n${_progressBar(progress.done, progress.total)} '
        '${progress.phase} ${progress.done} of ${progress.total}';
  }

  String _bodyFor(BikeState bike) => switch (_step) {
        SetupStep.intro => setupIntroBody,
        SetupStep.turnOff1 || SetupStep.turnOff2 =>
          'Switch the bike off with its power button. Do not ride it and do '
              'not change anything on the handlebar.',
        SetupStep.turnOn1 || SetupStep.turnOn2 =>
          'Switch the bike on again. The app connects again by itself, '
              'usually in 5 to 30 seconds.',
        SetupStep.readBoot1 || SetupStep.readBoot2 => 'The app reads the bike.',
        SetupStep.probing => _probingBody,
        SetupStep.done => _summaryFor(bike.region) ?? 'Nothing was measured.',
        SetupStep.failed => _failure ?? 'The setup stopped.',
      };

  /// Stands in for a result that cannot be missing: [_capabilities] and
  /// [_signature] are both set before the step becomes [SetupStep.done].
  ///
  /// [region] is the bike's own, resolved region, not
  /// [BikeCapabilities.detectedRegion]: the detected one is null for every CH
  /// bike (a CH bike answers the same EU bank an EU bike answers), and a null
  /// region prints every cap in mph — a CH rider would read "resets the mode to
  /// 16 mph" instead of "25 km/h". [Bike.saveCapabilities] has already applied
  /// any detected region to the record by this step, so the record holds the
  /// answer both cases need.
  String? _summaryFor(BikeRegion? region) {
    final capabilities = _capabilities;
    final signature = _signature;
    if (capabilities == null || signature == null) {
      return null;
    }
    return setupSummary(capabilities, signature, region: region);
  }

  bool get _busy => switch (_step) {
        SetupStep.turnOff1 ||
        SetupStep.turnOn1 ||
        SetupStep.readBoot1 ||
        SetupStep.probing ||
        SetupStep.turnOff2 ||
        SetupStep.turnOn2 ||
        SetupStep.readBoot2 =>
          true,
        SetupStep.intro || SetupStep.done || SetupStep.failed => false,
      };

  @override
  Widget build(BuildContext context) {
    // Watched, not read: it holds the notifier alive for as long as the
    // wizard is on screen, whatever happens to the page below it.
    final bike = ref.watch(bikeProvider(widget.bikeID));
    final theme = Theme.of(context);
    return PopScope(
      // The back gesture is a cancel like any other, and it has to undo the
      // same thing. Here rather than in [dispose]: the page is still mounted
      // at this moment.
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _finish();
        }
      },
      child: _scaffold(theme, bike),
    );
  }

  Widget _scaffold(ThemeData theme, BikeState bike) {
    return Scaffold(
      backgroundColor: SDSurface.page,
      appBar: AppBar(
        backgroundColor: SDSurface.page,
        foregroundColor: SDSurface.text,
        title: Text(bike.name, style: theme.textTheme.titleMedium),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _title,
                key: const ValueKey('setupTitle'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: SDSurface.text,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _bodyFor(bike),
                        key: const ValueKey('setupBody'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: SDSurface.label),
                      ),
                      if (_hint != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _hint!,
                          key: const ValueKey('setupHint'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: SDSurface.warning,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (_busy) ...[
                        const SizedBox(height: 24),
                        const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              ..._actions(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _actions() => switch (_step) {
        SetupStep.intro => [
            _primary('Start', const ValueKey('setupStart'), _run),
          ],
        SetupStep.turnOff1 ||
        SetupStep.turnOff2 ||
        SetupStep.readBoot1 ||
        SetupStep.readBoot2 =>
          [
            _secondary('Cancel', const ValueKey('setupCancel'), _cancel),
          ],
        SetupStep.probing => [
            // The sweep cannot actually be stopped mid-flight (see
            // _cancelPending), so a tap here disables the button rather than
            // pretending it worked — the rider's tap is acknowledged in the
            // body text instead.
            _secondary(
                _cancelPending ? 'Stopping…' : 'Cancel',
                const ValueKey('setupCancel'),
                _cancelPending ? null : _requestCancel),
          ],
        SetupStep.turnOn1 || SetupStep.turnOn2 => [
            // The manual connect never consults the auto-reconnect setting,
            // so this is the way back for a bike the app is not allowed to
            // chase.
            _primary('Connect', const ValueKey('setupConnect'), () {
              ref
                  .read(connectionHandlerProvider(widget.bikeID).notifier)
                  .connect();
            }),
            const SizedBox(height: 8),
            _secondary('Cancel', const ValueKey('setupCancel'), _cancel),
          ],
        SetupStep.done => [
            _primary('Done', const ValueKey('setupDone'),
                () => Navigator.of(context).maybePop()),
          ],
        SetupStep.failed => [
            _primary('Try again', const ValueKey('setupRetry'), _run),
            const SizedBox(height: 8),
            _secondary('Close', const ValueKey('setupClose'), _cancel),
          ],
      };

  Widget _primary(String label, Key key, VoidCallback onPressed) =>
      ElevatedButton(
        key: key,
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xff441DFC).withAlpha(51),
          foregroundColor: const Color(0xff441DFC),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(label),
      );

  Widget _secondary(String label, Key key, VoidCallback? onPressed) =>
      TextButton(
        key: key,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: SDSurface.muted,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
        child: Text(label),
      );
}
