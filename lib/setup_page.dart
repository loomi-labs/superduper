import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/theme.dart';

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
  ({String phase, int done, int total})? _progress;

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

  /// The step's wait for the link to go down or come back, and which of the
  /// two it waits for.
  Completer<bool>? _waiter;
  bool _wantConnected = false;
  Timer? _hintTimer;

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

  /// Everything a wizard that did not save anything has to undo: just the
  /// window. Unlike the old one-boot guide, nothing is staged on the bike
  /// before the window opens, so there is no bike-side state to put back.
  void _finish() {
    if (_finished) {
      return;
    }
    _finished = true;
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
    return waiter.future.whenComplete(() {
      _hintTimer?.cancel();
      _hintTimer = null;
      _waiter = null;
    });
  }

  static const _offHintText =
      'The bike is still connected. Hold the power button until the bike '
      'is off.';
  static const _onHintText =
      'The app cannot find the bike. Make sure the bike is on and near the '
      'phone, then use Connect.';

  /// The whole flow, in the order the rider walks it. Every await is
  /// followed by the same question: is this page still the one the rider is
  /// looking at. Re-entered from the top by both the intro's Start and a
  /// retry after [SetupStep.failed] — a full restart is the only safe choice
  /// once anything has failed: a [_bootA] or [_capabilities] left over from
  /// an earlier, incomplete attempt must never be trusted for a fresh probe
  /// or a fresh second boot.
  Future<void> _run() async {
    _cancelled = false;
    _finished = false;
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
    // [Bike.probeCapabilities] refuses outright while [_calibrating] is
    // set — it writes the bus directly, below writeStateData, and does not
    // expect the write-suppression window to be held around it. The window
    // is not needed here either: nothing but the probe's own writes touches
    // the bike until the window reopens below, right after, to protect the
    // parting read and the second power cycle the same way the first one
    // was protected.
    _bike.setCalibrating(false);
    final capabilities = await _bike.probeCapabilities(bootA,
        onProgress: (phase, done, total) {
      if (!mounted) {
        return;
      }
      setState(() => _progress = (phase: phase, done: done, total: total));
    });
    _bike.setCalibrating(true);
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
    // more plain read, right after: nothing else touches the bike inside the
    // (now reopened) calibrating window between the two calls.
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
        capabilities: _capabilities!,
        bootA: _bootA!,
        parting: _parting!,
        bootB: _bootB!);
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

  String get _body => switch (_step) {
        SetupStep.intro => setupIntroBody,
        SetupStep.turnOff1 || SetupStep.turnOff2 =>
          'Switch the bike off with its power button. Do not ride it and do '
              'not change anything on the handlebar.',
        SetupStep.turnOn1 || SetupStep.turnOn2 =>
          'Switch the bike on again. The app connects again by itself, '
              'usually in 5 to 30 seconds.',
        SetupStep.readBoot1 || SetupStep.readBoot2 => 'The app reads the bike.',
        SetupStep.probing => _probingBody,
        SetupStep.done => _summary ?? 'Nothing was measured.',
        SetupStep.failed => _failure ?? 'The setup stopped.',
      };

  /// Stands in for a result that cannot be missing: [_capabilities] and
  /// [_signature] are both set before the step becomes [SetupStep.done].
  String? get _summary {
    final capabilities = _capabilities;
    final signature = _signature;
    if (capabilities == null || signature == null) {
      return null;
    }
    return setupSummary(capabilities, signature);
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
                        _body,
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
        SetupStep.readBoot2 ||
        SetupStep.probing =>
          [
            _secondary('Cancel', const ValueKey('setupCancel'), _cancel),
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

  Widget _secondary(String label, Key key, VoidCallback onPressed) =>
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
