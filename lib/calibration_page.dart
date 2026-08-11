import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/theme.dart';

/// What the app measured, in the rider's words.
///
/// The names come out of the firmware table, so the guide can only ever say
/// what the bike really reports. A byte the firmware kept is named as kept: it
/// is half the answer, and hiding it would make a bike that keeps its assist
/// look badly calibrated.
String bootSignatureSummary(BootSignature signature) {
  final wire = signature.bootWire;
  final assist = signature.bootAssist;
  if (wire == null && assist == null) {
    return 'Your bike keeps its mode and its assist through a power cycle. '
        'Automatic power-cycle detection is not possible on this bike. Your '
        'locks and your startup values still work; the app applies the startup '
        'values only when you connect it yourself.';
  }
  if (assist == null) {
    return 'Your bike resets its mode to ${_wireName(wire!)}. It keeps its '
        'assist, so only the mode is used to see a power cycle.';
  }
  if (wire == null) {
    return 'Your bike resets its assist to $assist. It keeps its mode, so only '
        'the assist is used to see a power cycle.';
  }
  return 'Your bike resets its mode to ${_wireName(wire)} and its assist to '
      '$assist. The app uses both to see a power cycle.';
}

/// The firmware profile a wire byte names, or the raw byte for a firmware the
/// app does not know.
String _wireName(int wire) => wire >= 0 && wire < firmwareProfiles.length
    ? profileByWire(wire).name
    : 'mode $wire';

/// The date a signature was measured, as the settings sheet shows it.
String calibrationDate(DateTime at) => '${at.year}-'
    '${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')}';

/// Opens the guide over the page that asks for it.
///
/// A pushed page and not a sheet: the flow spans a power cycle of the bike, so
/// it lives for a minute or more, and a sheet is one stray drag away from
/// being dismissed in the middle of it — which would leave the rider's bike on
/// a staged state with no result.
Future<void> showCalibration(BuildContext context, String bikeID) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => CalibrationPage(bikeID: bikeID)));

/// Where the guide is. One screen per step, and every one of them can be left.
enum CalibrationStep {
  /// What the guide is about to do, with Later and Start.
  intro,

  /// The staging write is going on the bike.
  staging,

  /// Waiting for the rider to switch the bike off.
  turnOff,

  /// Waiting for the bike to come back.
  turnOn,

  /// The recording window is open.
  recording,

  /// A signature was measured and saved.
  done,

  /// The guide gave up, with a reason.
  failed,
}

class CalibrationPage extends ConsumerStatefulWidget {
  const CalibrationPage(
      {super.key, required this.bikeID, this.schedule = Bike.bootWindowSchedule});

  final String bikeID;

  /// The recording window's read schedule. Only a test passes another one: a
  /// widget test has to walk the whole flow, and the real window spends eight
  /// seconds in one step of it.
  final List<Duration> schedule;

  @override
  ConsumerState<CalibrationPage> createState() => _CalibrationPageState();
}

class _CalibrationPageState extends ConsumerState<CalibrationPage> {
  /// How long a step waits before it says the rider may have to help.
  static const _offHint = Duration(seconds: 30);
  static const _onHint = Duration(seconds: 45);

  var _step = CalibrationStep.intro;

  /// The extra line a step shows when it has waited long enough to suspect
  /// something went wrong. Never a failure — the rider may just be slow.
  String? _hint;

  String? _failure;
  BootSignature? _signature;

  ({int assist, int wire})? _preOff;

  /// The assist level the rider had before the guide staged its own. Put back
  /// on a cancel, so a guide that measured nothing leaves nothing behind.
  int? _priorAssist;

  bool _guardOpen = false;
  bool _cancelled = false;
  bool _finished = false;

  /// The step's wait for the link to go down or come back, and which of the
  /// two it waits for.
  Completer<bool>? _waiter;
  bool _wantConnected = false;
  Timer? _hintTimer;

  /// Taken once: the guide has to release the write-suppression window even
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
    // write through. [setCalibrating] touches nothing but its own flag.
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

  /// Everything a guide that did not save a signature has to undo: the window,
  /// and the assist level it staged on the bike.
  void _finish({required bool keepStagedState}) {
    if (_finished) {
      return;
    }
    _finished = true;
    _releaseGuard();
    final prior = _priorAssist;
    _priorAssist = null;
    if (keepStagedState || prior == null) {
      return;
    }
    // After the window is closed, never before: a write inside it is dropped.
    // While the bike is away this does nothing at all, which is right — the
    // app then holds no state the bike does not have.
    _bike.setAssist(prior);
  }

  void _cancel() {
    _cancelled = true;
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(false);
    }
    _finish(keepStagedState: false);
    Navigator.of(context).maybePop();
  }

  void _fail(String reason) {
    _finish(keepStagedState: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _failure = reason;
      _hint = null;
      _step = CalibrationStep.failed;
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

  /// The whole flow, in the order the rider walks it. Every await is followed
  /// by the same question: is this page still the one the rider is looking at.
  Future<void> _run() async {
    _cancelled = false;
    _finished = false;
    setState(() {
      _step = CalibrationStep.staging;
      _hint = null;
      _failure = null;
    });
    final prior = ref.read(bikeProvider(widget.bikeID)).assist;
    final preOff = await _bike.stageForCalibration();
    if (!_alive) {
      return;
    }
    if (preOff == null) {
      _fail('The app could not put a known state on the bike. Make sure the '
          'bike is on, standing still and in range, then try again.');
      return;
    }
    _preOff = preOff;
    _priorAssist = prior;
    // Only now: the window suppresses every settings write, and the staging
    // write is one. From here to the signature nothing of the app's touches
    // the bike, which is what makes the measurement worth anything.
    _bike.setCalibrating(true);
    _guardOpen = true;
    setState(() {
      _step = CalibrationStep.turnOff;
      _hint = null;
    });
    final off = await _waitForConnection(
        connected: false,
        hintAfter: _offHint,
        hint: 'The bike is still connected. Hold the power button until the '
            'bike is off.');
    if (!off || !_alive) {
      return;
    }
    setState(() {
      _step = CalibrationStep.turnOn;
      _hint = null;
    });
    final on = await _waitForConnection(
        connected: true,
        hintAfter: _onHint,
        hint: 'The app cannot find the bike. Make sure the bike is on and near '
            'the phone, then use Connect.');
    if (!on || !_alive) {
      return;
    }
    setState(() {
      _step = CalibrationStep.recording;
      _hint = null;
    });
    final settled = await _bike.recordBootWindow(schedule: widget.schedule);
    if (!_alive) {
      return;
    }
    if (settled == null) {
      _fail('The bike gave no answer during the measurement. Try again.');
      return;
    }
    final signature =
        _bike.saveBootSignature(preOff: _preOff!, settled: settled);
    // The staged state is measured and saved, so there is nothing to put back:
    // the bike holds what it booted with, and the poll adopts it.
    _finish(keepStagedState: true);
    if (!mounted) {
      return;
    }
    setState(() {
      _signature = signature;
      _step = CalibrationStep.done;
    });
  }

  String get _title => switch (_step) {
        CalibrationStep.intro => 'Calibrate power-cycle detection',
        CalibrationStep.staging => 'Preparing the bike',
        CalibrationStep.turnOff => 'Turn the bike off',
        CalibrationStep.turnOn => 'Turn the bike on',
        CalibrationStep.recording => 'Measuring the bike',
        CalibrationStep.done => 'Calibration complete',
        CalibrationStep.failed => 'Calibration stopped',
      };

  String get _body => switch (_step) {
        CalibrationStep.intro =>
          'The app measures what your bike reports after a power-on. It then '
              'knows a power cycle from a lost connection, and your startup '
              'values apply at the right moment.\n\nPark the bike. You switch '
              'it off one time and on again. This takes about one minute.',
        CalibrationStep.staging =>
          'The app puts a known state on the bike to measure against.',
        CalibrationStep.turnOff =>
          'Switch the bike off with its power button. Do not ride it and do '
              'not change anything on the handlebar.',
        CalibrationStep.turnOn =>
          'Switch the bike on again. The app connects again by itself, usually '
              'in 5 to 30 seconds.',
        CalibrationStep.recording =>
          'The app reads the bike for a few seconds. Do not touch the bike or '
              'the phone.',
        CalibrationStep.done =>
          bootSignatureSummary(_signature ?? _emptySignature),
        CalibrationStep.failed => _failure ?? 'The guide stopped.',
      };

  /// Stands in for a result that cannot be missing: [_signature] is set before
  /// the step becomes [CalibrationStep.done].
  BootSignature get _emptySignature => BootSignature(
      measuredAt: DateTime.now(), preOffWire: 0, preOffAssist: 0);

  bool get _busy =>
      _step == CalibrationStep.staging ||
      _step == CalibrationStep.turnOff ||
      _step == CalibrationStep.turnOn ||
      _step == CalibrationStep.recording;

  @override
  Widget build(BuildContext context) {
    // Watched, not read: it holds the notifier alive for as long as the guide
    // is on screen, whatever happens to the page below it.
    final bike = ref.watch(bikeProvider(widget.bikeID));
    final theme = Theme.of(context);
    return PopScope(
      // The back gesture is a cancel like any other, and it has to undo the
      // same things. Here rather than in [dispose]: the page is still mounted
      // at this moment, so the staged assist can still go back on the bike.
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _finish(keepStagedState: false);
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
                key: const ValueKey('calibrationTitle'),
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
                        key: const ValueKey('calibrationBody'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: SDSurface.label),
                      ),
                      if (_hint != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _hint!,
                          key: const ValueKey('calibrationHint'),
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
        CalibrationStep.intro => [
            _primary('Start', const ValueKey('calibrationStart'), _run),
            const SizedBox(height: 8),
            _secondary('Later', const ValueKey('calibrationLater'), _cancel),
          ],
        CalibrationStep.staging || CalibrationStep.recording => [
            _secondary('Cancel', const ValueKey('calibrationCancel'), _cancel),
          ],
        CalibrationStep.turnOff => [
            _secondary('Cancel', const ValueKey('calibrationCancel'), _cancel),
          ],
        CalibrationStep.turnOn => [
            // The manual connect never consults the auto-reconnect setting, so
            // this is the way back for a bike the app is not allowed to chase.
            _primary('Connect', const ValueKey('calibrationConnect'), () {
              ref
                  .read(connectionHandlerProvider(widget.bikeID).notifier)
                  .connect();
            }),
            const SizedBox(height: 8),
            _secondary('Cancel', const ValueKey('calibrationCancel'), _cancel),
          ],
        CalibrationStep.done => [
            _primary('Done', const ValueKey('calibrationDone'),
                () => Navigator.of(context).maybePop()),
          ],
        CalibrationStep.failed => [
            _primary('Try again', const ValueKey('calibrationRetry'), _run),
            const SizedBox(height: 8),
            _secondary('Close', const ValueKey('calibrationClose'), _cancel),
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
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
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
