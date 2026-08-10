# Ride-Log Findings Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

This is a living plan. Append new tasks before the "Self-review notes" section and continue the task numbering. Three end-to-end checks close their goals: Task 6 (timer-visible behavior), Task 9 (UI), Task 15 (reconnect and pins). Extend the matching one for new behavior instead of adding a fourth.

**Goal 1 (Tasks 1-6):** Fix the five defects that the 2026-08-08 production ride log exposed: the stale-guard race that opened a 1.2 s unenforced window, the false heals after ~10 % of switches, the speed trace that stops during switching storms, the 7 s poll that the docs promise as 5 s, and the light/assist/mode taps that the app drops silently while disconnected.

**Goal 2 (Tasks 7-9):** Redesign the bike page to design draft A. The current page paints every card with the bike's full gradient, which the user finds too colorful, and the mode and assist chips wrap to a second row, which looks broken. Draft A keeps neutral surfaces for every bike and spends the bike's color only as an accent.

**Goal 3 (Tasks 10-15):** Make the padlock a three-state pin (open / startup / locked), apply the pinned values when the bike was power-cycled, fix the reconnect ladder that makes that detectable, and delete the Background Lock button by deriving the service from what actually needs enforcing. The full design, with the measurements behind every number, is `scratch/lock-startup/design.md` — **read it before starting any of Tasks 10-15.**

**Goal 4 (Task 16):** Let a custom mode carry a throttle above 32 km/h. The off-road profile supports a throttle, so the current 32 km/h ceiling is wrong. Such a mode has to ride an unlimited base profile, which moves the limit from the firmware to the app — the task carries two fail-safes for that.

**Goal 5 (Task 17):** Name a new custom mode after its speed (`30 km/h`) instead of `Custom`, until the rider types a name of their own.

**Architecture:** All control-loop fixes live in the `Bike` notifier (`lib/bike.dart`) and one new pure helper in `lib/models.dart`. The UI fix gates the three control widgets on the connection state. The redesign adds one token file (`lib/theme.dart`), reshapes the card widgets in `lib/widgets.dart`, and rewrites the four control widgets in `lib/bike.dart` to use them. Goals 1, 2, 4 and 5 change no BLE layer and no schema. Goal 3 changes both: Task 11 edits `lib/repository.dart`, and Tasks 10 and 13 change `@freezed` fields and run `build_runner`.

**Tech Stack:** Flutter, Riverpod (codegen), `flutter_test` with the existing `FakeBikeStore` harness.

**Decisions already made by the user (do not revisit):**
- Finding 2 (offline taps): disable the controls. Do not queue changes. Do not add snackbars.
- Finding 6 (oscillation at cruise): keep as is. It is the limiting mechanism. No task exists for it.
- The redesign is **draft A**, from the drafts at https://claude.ai/code/artifact/8d2406c0-dfad-41fc-8d4a-bc282d2d11a8 . Draft H (titles outside the cards, assist as five full-width rows) was rejected: it is not compact enough. Do not move the section titles out of the cards, and do not turn assist into a row-per-level list.
- Mode keeps a row-per-mode list, because the list is variable length. Assist becomes a five-segment control, because the count is fixed at 0-4 and five equal segments can never wrap.

## Global Constraints

- Use `jj` for version control, never raw `git`. Commit each task with `jj commit -m "..."`. The plan is the user's approval for these commits.
- Never edit `*.g.dart` or `*.freezed.dart`. Tasks 1-9 change no annotation, so do not run `build_runner` for them. Tasks 10 and 13 change `@freezed` fields and **must** run `dart run build_runner build`; every task after 10 depends on its output.
- Never run `dart format` in this repo.
- Write all comments and commit messages in ASD-STE100 style: short sentences, active voice.
- Match the codebase comment style: comments explain *why*, in full sentences.
- Verify each task with `flutter analyze` (must be clean) and the named test command.
- Test helpers already in `test/bike_test.dart` that tasks below reuse: `makeContainer()`, `openBike()`, `settle()`, `bikeWire()`, `bikeAssist()`, `seedBikesFile()`, and the consts `id`, `tour30`. Custom stores are injected with `ProviderContainer(overrides: [fakeBikeStoreProvider.overrideWithValue(store)])` (see the existing pattern at `test/bike_test.dart:512`).
- Background knowledge: a settings write packet is `[0, 209, light, assist, wire, 0, ...]` — the wire byte is index 4. A settings read-back is `[3, 0, assist, walk, light, wire, ...]` — the wire byte is index 5. `tour30` (limit 30, throttle) rides base wire 1 and cap wire 4.

---

### Task 1: Compute the wire byte at the queue head (finding 1 — the 1.2 s unenforced window)

**Why.** The log shows this at 20:12:29: the poll composed a write (handlebar assist change) with the wire byte read from `_assertedWire` at *invocation* time. A speed sample crossed the limit 5 ms later and set `_assertedWire` to the cap. The poll write then ran first, put the old base wire on the bike, and reset `_assertedWire`. The stale guard dropped the queued switch write. The bike rode uncapped above the limit for 1.2 s. The fix: compute the wire byte inside the register-queue slot, at the moment the packet goes on the wire. Then any write of an unchanged switching mode carries the freshest wire intent, and the ordering of poll writes and switch writes stops mattering.

**Files:**
- Modify: `lib/models.dart` (add `wireForWrite` near `initialWireFor`, ~line 271)
- Modify: `lib/bike.dart:462-473` (wire computation in `writeStateData`) and `lib/bike.dart:213` (add a test hook next to `_onSpeedSample`)
- Test: `test/models_test.dart`, `test/bike_test.dart`

**Interfaces:**
- Produces: `int wireForWrite({required SelectedMode sel, required bool modeChanged, required bool nowSwitching, required int assertedWire})` in `lib/models.dart`.
- Produces: `@visibleForTesting void debugHandleSpeedSample(double speedKmh)` on `Bike` — Task 2's test uses it too.

- [ ] **Step 1: Write the failing unit tests for the pure helper**

Add to `test/models_test.dart` (top-level group; define the mode locally so the group is self-contained):

```dart
group('wireForWrite', () {
  // Base wire 1 (32 km/h + throttle), cap wire 4 (EPAC 25).
  const w30 = CustomMode(id: 'w1', name: 'W30', limitKmh: 30, throttle: true);

  test('an unchanged switching mode carries the wire asserted now', () {
    expect(
        wireForWrite(
            sel: const CustomSelection(w30),
            modeChanged: false,
            nowSwitching: true,
            assertedWire: 4),
        4);
    expect(
        wireForWrite(
            sel: const CustomSelection(w30),
            modeChanged: false,
            nowSwitching: true,
            assertedWire: 1),
        1);
  });

  test('a mode change enters on the initial wire', () {
    expect(
        wireForWrite(
            sel: const CustomSelection(w30),
            modeChanged: true,
            nowSwitching: true,
            assertedWire: 4),
        1,
        reason: 'a mode is entered on its base profile');
  });

  test('a mode that never switches carries its own wire', () {
    expect(
        wireForWrite(
            sel: NativeSelection(profileByWire(2)),
            modeChanged: false,
            nowSwitching: false,
            assertedWire: 4),
        2);
  });

  test('a foreign asserted wire falls back to the initial wire', () {
    expect(
        wireForWrite(
            sel: const CustomSelection(w30),
            modeChanged: false,
            nowSwitching: true,
            assertedWire: 9),
        1,
        reason: 'a wire the mode never asserts is no memory of anything');
  });
});
```

- [ ] **Step 2: Run the unit tests, verify they fail**

Run: `flutter test test/models_test.dart --name wireForWrite`
Expected: FAIL — `wireForWrite` is not defined.

- [ ] **Step 3: Implement `wireForWrite` in `lib/models.dart`**

Place it directly after `initialWireFor` (~line 275):

```dart
/// The wire byte a settings write must carry, given the wire the app asserts
/// at this moment. A mode change and a non-switching mode enter on the
/// selection's initial wire; an unchanged switching mode keeps the asserted
/// wire, normalised through [assertsWire] exactly as [wireVerdict] normalises
/// it.
///
/// Callers evaluate this at the head of the register queue, never at compose
/// time: a write composed before a speed transition must not put the
/// pre-transition wire back on the bike.
int wireForWrite({
  required SelectedMode sel,
  required bool modeChanged,
  required bool nowSwitching,
  required int assertedWire,
}) {
  if (modeChanged || !nowSwitching) {
    return initialWireFor(sel);
  }
  return assertsWire(sel, assertedWire) ? assertedWire : initialWireFor(sel);
}
```

- [ ] **Step 4: Run the unit tests, verify they pass**

Run: `flutter test test/models_test.dart --name wireForWrite`
Expected: PASS (4 tests).

- [ ] **Step 5: Add the test hook to `Bike`**

In `lib/bike.dart`, directly after `_onSpeedSample` (~line 242):

```dart
/// Delivers one speed sample synchronously, so a test can interleave a switch
/// decision with a write that already sits in the register queue.
@visibleForTesting
void debugHandleSpeedSample(double speedKmh) => _onSpeedSample(speedKmh);
```

- [ ] **Step 6: Write the failing race test**

Add to the `speed switching` group in `test/bike_test.dart`:

```dart
test('a write composed before a switch still carries the new wire', () async {
  final container = makeContainer();
  await openBike(container,
      region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
  final bike = container.read(bikeProvider(id).notifier);
  final store = container.read(fakeBikeStoreProvider);
  store.setSpeed(id, 10);
  await settle();
  expect(bikeWire(container), 1);

  // The rider changes assist on the handlebar; the poll answers with a
  // write. The speed crosses the limit while that write waits in the
  // register queue — the interleaving of the 2026-08-08 20:12:29 ride log.
  bike.writeStateData(container.read(bikeProvider(id)).copyWith(assist: 3));
  bike.debugHandleSpeedSample(35);
  await settle();

  expect(bikeWire(container), 4,
      reason: 'the queued write must not put the pre-switch wire back');
  expect(bikeAssist(container), 3,
      reason: 'the assist change itself has to land');
});
```

- [ ] **Step 7: Run the race test, verify it fails**

Run: `flutter test test/bike_test.dart --name "a write composed before a switch"`
Expected: FAIL — `bikeWire` is 1. The queued write carried the stale wire, and the stale guard dropped the switch write (the log shows `Dropping a write composed before a change`).

- [ ] **Step 8: Move the wire computation into the queue slot**

In `lib/bike.dart`, `writeStateData`. Replace lines 462-473 (the `asserted` and `wire` computation) with a local function plus a mutable slot result:

```dart
    // Evaluated at the queue head, not here: a speed transition can change
    // [_assertedWire] while this write waits behind other register work, and
    // the packet must carry the wire the app intends at the moment it goes on
    // the wire — see the 2026-08-08 ride log, 20:12:29. A wire the selection
    // never asserts is normalised exactly as [wireVerdict] normalises it, so
    // a heal write can never contradict the verdict that asked for it.
    int computeWire() => wireForWrite(
        sel: newSel,
        modeChanged: modeChanged,
        nowSwitching: nowSwitching,
        assertedWire: _assertedWire);
    var wire = computeWire();
```

Inside the `_withRegister` slot, directly before `data = newState.toWriteData(wire: wire);` (line 516), add the re-evaluation:

```dart
          wire = computeWire();
```

Leave line 541 (`_assertedWire = wire;`) unchanged: for the `saveToBike: false` path the compose-time value is still used, and for the write path the slot updated `wire`.

- [ ] **Step 9: Run the race test, verify it passes**

Run: `flutter test test/bike_test.dart --name "a write composed before a switch"`
Expected: PASS.

- [ ] **Step 10: Run the full suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all tests pass (262 before this plan), analyzer clean.

- [ ] **Step 11: Commit**

```bash
jj commit -m "fix: compute the wire byte at the register-queue head

A write composed before a speed transition carried the pre-transition
wire and the stale guard then dropped the switch write. The 2026-08-08
ride log shows a 1.2 s window above the limit from this race."
```

---

### Task 2: Skip the poll verdict while a settings write is queued (finding 4 — false heals)

**Why.** The log shows 11 heals right after switches. A poll read that entered the register queue before a switch write returns the pre-switch wire — true, but already outdated. `wireVerdict` compares it against the fresh `_assertedWire` and asks for a heal, so the app writes the same packet twice, ~90 ms apart. The queued write already asserts the new wire; the verdict must not judge stale data. Fix: count queued settings writes; when one is pending, skip this poll's state update. The next poll (5 s) judges fresh data.

**Files:**
- Modify: `lib/bike.dart` (`writeStateData` ~line 492, `updateStateDataNow` ~line 355)
- Test: `test/bike_test.dart`

**Interfaces:**
- Consumes: `debugHandleSpeedSample` from Task 1.
- Produces: private `_pendingWrites` counter; no public surface.

- [ ] **Step 1: Write the failing test**

Add near the other store subclasses at the top of `test/bike_test.dart`:

```dart
/// A bike that records every write, so a test can count how often the app
/// put a given wire byte on the bus.
class _CountingWriteStore extends FakeBikeStore {
  final writes = <List<int>>[];

  @override
  void write(String deviceId, List<int> data) {
    writes.add(List.of(data));
    super.write(deviceId, data);
  }
}
```

Add to the `wire verdict in the poll` group:

```dart
test('the poll does not heal while a switch write waits in the queue',
    () async {
  final store = _CountingWriteStore();
  final container = ProviderContainer(overrides: [
    fakeBikeStoreProvider.overrideWithValue(store),
  ]);
  addTearDown(container.dispose);
  await openBike(container,
      region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
  final bike = container.read(bikeProvider(id).notifier);
  store.setSpeed(id, 10);
  await settle();
  expect(bikeWire(container), 1);

  // The poll read enters the register queue first; the switch decision
  // lands behind it. The read then reports wire 1 — true, but outdated.
  final poll = bike.updateStateDataNow();
  bike.debugHandleSpeedSample(35);
  await poll;
  await settle();

  expect(bikeWire(container), 4);
  final capWrites =
      store.writes.where((d) => d.first == 0 && d[4] == 4).length;
  expect(capWrites, 1,
      reason: 'the queued switch write already asserts wire 4; a heal '
          'would put the same packet on the bus twice');
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `flutter test test/bike_test.dart --name "does not heal while a switch write"`
Expected: FAIL — `capWrites` is 2 (the switch write plus the heal write).

- [ ] **Step 3: Implement the pending-write gate**

In `lib/bike.dart`, add a field next to `_registerQueue` (~line 101):

```dart
  /// Settings writes queued but not yet completed. A poll read that returns
  /// while this is non-zero predates the write behind it, so its wire byte
  /// says nothing the verdict may act on.
  int _pendingWrites = 0;
```

In `writeStateData`, wrap the existing `try { await _withRegister(...) } catch ...` block (lines 492-525): increment before, decrement in a new `finally`:

```dart
      _pendingWrites++;
      try {
        // ... existing _withRegister block, unchanged ...
      } catch (e) {
        // ... existing catch body, unchanged ...
      } finally {
        _pendingWrites--;
      }
```

Note: the existing `catch` body ends in `return;`. A `finally` on the same statement still runs before that return, so the counter cannot leak.

In `updateStateDataNow`, after the `_lastKnown` update (~line 355) and before `var newState = state.updateFromData(data);`:

```dart
    if (_pendingWrites > 0) {
      // This read predates a settings write that waits in the queue. Judging
      // its wire byte would heal against the past — the ride log shows the
      // same packet written twice after ~10 % of switches. The next poll
      // judges fresh data.
      _logD('Skipping state update, a write is pending');
      return;
    }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `flutter test test/bike_test.dart --name "does not heal while a switch write"`
Expected: PASS.

- [ ] **Step 5: Run the full suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean. Watch the `wire verdict in the poll` group closely: those tests set a foreign wire and expect a heal. They must still pass, because no write is pending in them. If one fails, the gate is too wide — re-check where the `return` sits.

- [ ] **Step 6: Commit**

```bash
jj commit -m "fix: skip the poll verdict while a settings write is queued

A poll read that entered the queue before a switch write reported the
pre-switch wire, and the verdict healed against it. The ride log shows
the same packet written twice after about 10 % of switches."
```

---

### Task 3: Give the speed trace its own steady timer (finding 3 — silent trace during storms)

**Why.** `logSpeedTrace()` and `_checkSpeedStream()` run from `_updateTimer`, and every write resets that timer through `_resetDebounce()`. During an oscillation storm (a switch every 2-4 s) the timer never reaches its 5 s interval, so the ride log loses its trace exactly when the limiter is busiest — the log shows a 62 s hole at 23-31 km/h. Fix: move the trace and the stream watchdog to their own periodic timer that only `build`/dispose touch.

**Files:**
- Modify: `lib/bike.dart` (fields ~line 57, `build` ~line 113, `_resetReadTimer` ~line 298)
- Test: `test/bike_test.dart` (`the ride log` group)

**Interfaces:**
- Produces: `@visibleForTesting Timer? get debugTraceTimer` on `Bike`.

- [ ] **Step 1: Write the failing test**

Add to the `the ride log` group in `test/bike_test.dart`:

```dart
test('a write does not silence the trace timer', () async {
  final container = makeContainer();
  final bike = await openBike(container, region: BikeRegion.ch);
  final before = bike.debugTraceTimer;
  expect(before, isNotNull);
  expect(before!.isActive, isTrue);

  // Writes reset the poll timer through the debounce. The trace must not
  // sit on that timer: during a switching storm it would never fire, and
  // the ride log would lose its trace exactly when limiting is busiest.
  bike.toggleLight();
  await settle();

  expect(identical(bike.debugTraceTimer, before), isTrue,
      reason: 'the trace timer must run steady through writes');
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `flutter test test/bike_test.dart --name "does not silence the trace timer"`
Expected: FAIL to compile — `debugTraceTimer` is not defined.

- [ ] **Step 3: Implement the steady timer**

In `lib/bike.dart`:

Field, next to `_updateTimer` (~line 58):

```dart
  /// Fires the ride-log trace and the speed-stream watchdog. Deliberately not
  /// [_updateTimer]: every write resets that one through [_resetDebounce], so
  /// during a switching storm it never fires — and the storm is exactly what
  /// the trace must record. Only [build] and dispose touch this timer.
  Timer? _traceTimer;

  @visibleForTesting
  Timer? get debugTraceTimer => _traceTimer;
```

In `build`, extend the existing `ref.onDispose` callback (~line 115):

```dart
      _traceTimer?.cancel();
      _traceTimer = null;
```

In `build`, after `_resetReadTimer();` (~line 124):

```dart
    _traceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!ref.mounted) {
        return;
      }
      _checkSpeedStream();
      logSpeedTrace();
    });
```

In `_resetReadTimer`, remove `_checkSpeedStream();`, `logSpeedTrace();`, and the comment above them ("Before the _writing return: ...") from the timer body. The body keeps only the `ref.mounted` guard, the `_writing` skip, and `updateStateData();`.

Update the doc comment on `logSpeedTrace` (~line 258): it says the trace shares its tick with the poll; it now shares its tick with the watchdog on the trace timer. Keep the `_speedTimeout` coupling sentence — that still holds.

- [ ] **Step 4: Run the test, verify it passes**

Run: `flutter test test/bike_test.dart --name "does not silence the trace timer"`
Expected: PASS.

- [ ] **Step 5: Run the full suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass. The existing tests never advance real time, so the new timer never fires in them.

- [ ] **Step 6: Commit**

```bash
jj commit -m "fix: run the speed trace on its own timer

Writes reset the poll timer, so a switching storm silenced the trace
and the watchdog for its whole duration. The 2026-08-08 ride log has a
62 s trace hole at 23-31 km/h from this."
```

---

### Task 4: Make the poll tick read immediately (finding 5 — 7 s effective poll)

**Why.** The timer fires every 5 s but its body calls `updateStateData()`, which waits out a 2 s debounce before the read. The effective poll period is 7 s; the log shows 8 traces/min where the code comments promise 12. The debounce exists to space user writes and to read the write echo 2 s after a write — both stay. Only the periodic tick skips it.

**Files:**
- Modify: `lib/bike.dart` (`_resetReadTimer` ~line 298)
- Test: none new — see Step 2 for why; Task 6 verifies the cadence end to end.

**Interfaces:**
- Consumes: `_isConnected` (exists, line 182).

- [ ] **Step 1: Change the tick body**

In `_resetReadTimer`, replace `updateStateData();` with:

```dart
      if (!_isConnected) {
        return;
      }
      // Straight to the read: updateStateData's 2 s debounce belongs to user
      // writes and to the post-write echo read, not to the idle poll. Through
      // the debounce the effective poll period was 7 s, not the 5 s the
      // interval promises. _withRegister still serializes this behind any
      // write in flight.
      unawaited(updateStateDataNow());
```

The connection check replaces the one that `updateStateData()` did internally. Keep the `_writing` skip above it unchanged.

- [ ] **Step 2: Note on tests**

No new unit test: the suite's `settle()` helper deliberately never advances real time (see its doc comment), and `fakeAsync` deadlocks on the notifier's real file I/O. The full suite guards against regressions; Task 6 verifies the 5 s cadence against the live app.

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean.

- [ ] **Step 3: Commit**

```bash
jj commit -m "fix: poll the bike state on the tick, not 2 s after it

The tick went through the write debounce, so the effective poll period
was 7 s. The debounce keeps its job for user writes and the post-write
echo read."
```

---

### Task 5: Disable the controls while the bike is disconnected (finding 2 — dropped taps)

**Why.** The log tail (20:35:28-41) shows four identical `Toggling light: false` lines and two identical `Setting assist to: 0` lines: `writeStateData` returns at its connection check before `state = newState`, so a disconnected tap changes nothing and gives no feedback. The user decided: grey the controls out, exactly like the Connect chip's disabled state. The lock buttons and the Background Lock card stay active — they are app state (`saveToBike: false`) and work offline.

**Files:**
- Modify: `lib/widgets.dart` (`SelectorItem`, ~line 7)
- Modify: `lib/bike.dart` (`EnhancedLightControlWidget` ~line 1124, `EnhancedModeControlWidget` ~line 1156, `EnhancedAssistControlWidget` ~line 1271)
- Test: `test/pickers_test.dart`

**Interfaces:**
- Consumes: `connectionHandlerProvider(bike.id)` and `SDBluetoothConnectionState.connected` from `lib/repository.dart`.
- Produces: `SelectorItem.onTap` becomes `final VoidCallback? onTap;` — a null tap renders the chip inert.

- [ ] **Step 1: Write the failing widget tests**

Add to `test/pickers_test.dart`. The file's `pumpControl` helper returns the container; the fake-bike handler reports connected, so the tests set the handler state directly — the same pattern `test/bike_test.dart` uses in 'a switching mode survives a connection dropout' (line ~365).

```dart
testWidgets('a disconnected bike ignores assist taps', (tester) async {
  final container = await pumpControl(tester,
      bike: BikeState.defaultState(id).copyWith(assist: 1),
      build: (b) => EnhancedAssistControlWidget(bike: b));
  // ignore: invalid_use_of_protected_member
  container.read(connectionHandlerProvider(id).notifier).state =
      SDBluetoothConnectionState.disconnected;
  await settle(tester);

  await tester.tap(find.byKey(const ValueKey('assistChip:3')));
  await settle(tester);

  expect(container.read(bikeProvider(id)).assist, 1,
      reason: 'an offline change cannot reach the bike; the control must '
          'not pretend it did');
  expect(bikeAssist(container), isNot(3));
});

testWidgets('a disconnected bike ignores mode taps', (tester) async {
  final container = await pumpControl(tester,
      bike: BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [tour30, sport45])
          .withSelectedMode(sport45.id),
      build: (b) => EnhancedModeControlWidget(bike: b));
  // ignore: invalid_use_of_protected_member
  container.read(connectionHandlerProvider(id).notifier).state =
      SDBluetoothConnectionState.disconnected;
  await settle(tester);

  await tester.tap(find.byKey(ValueKey('modeChip:${tour30.id}')));
  await settle(tester);

  expect(container.read(bikeProvider(id)).selectedMode.id, sport45.id);
});

testWidgets('a disconnected bike ignores light taps', (tester) async {
  final container = await pumpControl(tester,
      bike: BikeState.defaultState(id).copyWith(light: false),
      build: (b) => EnhancedLightControlWidget(bike: b));
  // ignore: invalid_use_of_protected_member
  container.read(connectionHandlerProvider(id).notifier).state =
      SDBluetoothConnectionState.disconnected;
  await settle(tester);

  await tester.tap(find.text('Light'));
  await settle(tester);

  expect(container.read(bikeProvider(id)).light, isFalse);
});
```

Add the missing imports to the file if the analyzer asks for them (`package:superduper/repository.dart`).

- [ ] **Step 2: Run the tests, verify they fail**

Run: `flutter test test/pickers_test.dart --name "a disconnected bike"`
Expected: The assist and mode tests FAIL — the tap goes through and changes the state. (If the tap does not change the state for a different reason, stop and find out why before touching the widgets: the test must fail for the right reason.) The light test may fail the same way.

- [ ] **Step 3: Make `SelectorItem.onTap` nullable**

In `lib/widgets.dart` (~line 7-20):

```dart
  final VoidCallback? onTap;
```

Keep the constructor parameter as is (`required this.onTap`); callers now may pass null. The `InkWell` at ~line 132 already accepts a null `onTap` and renders the chip inert.

- [ ] **Step 4: Gate the three control widgets**

In `lib/bike.dart`, in each of the three widgets' `build`, read the connection once:

```dart
    // Light and assist are bike truth: an offline change cannot stick, and
    // writeStateData drops it silently — the 2026-08-08 log tail shows four
    // identical light taps going nowhere. Honest UI: grey the card out, like
    // the Connect chip.
    final connected = ref.watch(connectionHandlerProvider(bike.id)) ==
        SDBluetoothConnectionState.connected;
```

`EnhancedLightControlWidget`: wrap the `DiscoverCard` in `Opacity(opacity: connected ? 1.0 : 0.5, child: ...)` and change the tap:

```dart
            onTap: connected
                ? () {
                    bikeControl.toggleLight();
                  }
                : null,
```

`EnhancedModeControlWidget`: wrap the `SelectorCard` in the same `Opacity`, and change each chip's tap:

```dart
                      onTap: connected
                          ? () {
                              bikeControl.selectMode(mode.id);
                            }
                          : null,
```

`EnhancedAssistControlWidget`: same `Opacity` wrap, and:

```dart
                  onTap: connected
                      ? () {
                          bikeControl.setAssist(level);
                        }
                      : null,
```

Do not touch `EnhancedLockWidget` or `EnhancedBackgroundLockWidget`.

- [ ] **Step 5: Run the tests, verify they pass**

Run: `flutter test test/pickers_test.dart`
Expected: the three new tests PASS, and the existing picker tests still PASS (they run against a connected fake bike, so the gate stays open for them).

- [ ] **Step 6: Run the full suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean.

- [ ] **Step 7: Commit**

```bash
jj commit -m "fix: disable light, mode, and assist controls while disconnected

writeStateData drops offline taps silently; the ride log tail shows
four identical light taps going nowhere. The cards now grey out and
ignore taps, like the Connect chip."
```

---

### Task 6: End-to-end check against a fake bike

**Why.** Tasks 3 and 4 change timer behavior that the unit suite cannot observe. Verify against the live app with a fake bike (no hardware needed) — the CLAUDE.md "Driving the UI" section describes the tooling.

- [ ] **Step 1: Start the driver target**

Run: `flutter run -d linux -t test_driver/app.dart --print-dtd`
Connect the Dart MCP to the printed DTD URI, call `set_frame_sync` with `enabled: false`, open the debug page, and create a fake bike.

- [ ] **Step 2: Verify the poll cadence (Task 4)**

Open the fake bike's page. Set its speed slider to a steady value above 0. Watch the `flutter run` log: `[Bike] [...] Speed ... km/h, wire ...` lines must arrive every ~5 s (they arrived every ~7 s before).

- [ ] **Step 3: Verify the trace through a switching storm (Tasks 1-3)**

Select a switching custom mode on the fake bike. Move the slider back and forth across the mode's limit every few seconds for one minute, so switches fire continuously. Check the log:
- `Speed ... km/h, wire ...` lines keep arriving every ~5 s through the storm (Task 3).
- Each `... km/h: wire X -> Y` line is followed by exactly one `Wrote data to bike: [0, 209, ..., Y, ...]` and no `Bike is on wire` line right after a switch (Tasks 1, 2).

- [ ] **Step 4: Report**

Record the observations in the task report. If a check fails, stop and fix before closing the plan.

---

### Task 7: Rebuild the bike page controls as draft A (goal 2)

**Why.** Every card on the page is painted with the bike's own gradient, so the page reads as three loud blocks and the state of a control competes with decoration. The mode and assist choices sit in a `Wrap`, so they spill onto a second run — the screenshot the user sent shows `OFFROAD` alone on a second line and assist `4` alone on a third. Draft A fixes both: surfaces are the same graphite for every bike, the bike's color survives as an accent and as one identity dot next to its name, and each control gets a layout that cannot wrap. The locks move from beside the card into the card header, which also stops the cards from being narrowed by a floating button.

**Order.** Run this **after Task 5**. Both edit `EnhancedLightControlWidget`, `EnhancedModeControlWidget` and `EnhancedAssistControlWidget`, and this task keeps Task 5's connection gate. All `lib/bike.dart` line numbers below predate Tasks 1-5, so locate the widgets by name, not by line.

**Files:**
- Create: `lib/theme.dart` (surface tokens)
- Create: `test/control_cards_test.dart`
- Modify: `lib/colors.dart` (two accessors on `ColorRange`, ~line 17)
- Modify: `lib/widgets.dart` (`SelectorCard` → `ControlCard` + `SelectorBody`, `SelectorChip` gains a layout, new `ControlSwitch`)
- Modify: `lib/bike.dart` (`BikePage` header and app bar, `EnhancedLockWidget`, and the four control widgets)
- Leave alone: `DiscoverCard` — `lib/select_page.dart` still uses it. Task 8 moves that screen.

**Interfaces:**
- Produces: `SDSurface` in `lib/theme.dart` — `page`, `card`, `border`, `row`, `text`, `label`, `muted`.
- Produces: `ColorRange.accent()` and `ColorRange.onAccent()`.
- Produces: `ControlCard`, `ControlSwitch`, `SelectorBody`, `enum SelectorLayout { rows, segments }`.
- Changes: `SelectorChip` gains `layout`, `accent` and `onAccent`; `SelectorCard` is deleted (only `lib/bike.dart` used it).
- Unchanged on purpose, because `test/pickers_test.dart` and the Flutter Driver workflow in CLAUDE.md depend on them: the `SelectorChip` type name, the `ValueKey` strings `modeChip:<id>` and `assistChip:<level>`, the tooltips `Select mode <name>` and `Select assist <n>`, the card title text `Light`, and `FontWeight.bold` on a selected label.

- [ ] **Step 1: Write the token file**

Create `lib/theme.dart`:

```dart
import 'package:flutter/material.dart';

/// The control page's fixed surfaces.
///
/// Only the accent comes from the bike's own colour range. These surfaces stay
/// the same for every bike, so a pastel or a near-white gradient can never wash
/// a card out: no surface is ever painted with the gradient.
abstract final class SDSurface {
  /// The page behind the cards.
  static const page = Color(0xff0e0f12);

  /// A card.
  static const card = Color(0xff17181c);

  /// A card's hairline, and an inactive divider.
  static const border = Color(0xff24262b);

  /// A row inside a card. One step lighter than the card, so every tap target
  /// shows its own edge.
  static const row = Color(0xff1e2025);

  static const text = Color(0xfff2f3f5);

  /// A title, and an icon that is not accented.
  static const label = Color(0xff9ba0a8);

  /// A caption, and an unselected label.
  static const muted = Color(0xff6b6e76);
}
```

- [ ] **Step 2: Add the accent accessors**

In `lib/colors.dart`, inside `ColorRange`, directly after `fontColor()` (~line 19):

```dart
  /// The one colour the control page paints with. The gradient itself survives
  /// only in the bike's identity dot next to its name.
  Color accent() => start;

  /// What a label on a solid [accent] fill must be. [fontColor] already picks
  /// for contrast against [start], and [accent] returns [start].
  Color onAccent() => fontColor();
```

- [ ] **Step 3: Write the failing widget tests**

Create `test/control_cards_test.dart`. These widgets are plain and stateless, so no provider container is needed:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/theme.dart';
import 'package:superduper/widgets.dart';

/// Draft A's rule, as a test: a card's surfaces never come from the bike's
/// colour, and the only place a label sits on a solid accent fill is a
/// selected segment — where it must be picked for contrast against it.
void main() {
  /// The card's own decorated box: the only one it paints with a border.
  /// Matched by that border rather than by position, so a wrapper widget
  /// inserting a box of its own cannot make this pick the wrong one.
  BoxDecoration cardDecoration(WidgetTester tester) => tester
      .widgetList<Container>(find.descendant(
          of: find.byType(ControlCard), matching: find.byType(Container)))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.border != null);

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(backgroundColor: SDSurface.page, body: child)));

  testWidgets('a card paints one surface for every bike colour', (tester) async {
    // 8 is Fiery Fuchsia, 26 is Pure White, 5 is a pastel. All must land on the
    // same graphite card: the old page painted each of these as a gradient.
    for (final colorIndex in [8, 26, 5]) {
      await pump(tester, ControlCard(title: 'Light', colorIndex: colorIndex));
      expect(cardDecoration(tester).color, SDSurface.card,
          reason: 'colour index $colorIndex must not reach the surface');
      expect(cardDecoration(tester).gradient, isNull);
    }
  });

  testWidgets('assist renders five segments and never wraps', (tester) async {
    await pump(
      tester,
      ControlCard(
        title: 'Assist',
        colorIndex: 8,
        showSwitch: false,
        body: SelectorBody(
          colorIndex: 8,
          layout: SelectorLayout.segments,
          items: [
            for (var level = 0; level <= 4; level++)
              SelectorItem(
                keyValue: 'assistChip:$level',
                label: '$level',
                tooltip: 'Select assist $level',
                selected: level == 2,
                onTap: () {},
              ),
          ],
        ),
      ),
    );

    final chips = tester.widgetList<SelectorChip>(find.byType(SelectorChip));
    expect(chips, hasLength(5));
    expect(chips.every((c) => c.layout == SelectorLayout.segments), isTrue);
    expect(find.byType(Wrap), findsNothing,
        reason: 'a Wrap is what put assist 4 on its own line');

    // One row: every segment shares the row's vertical centre.
    final tops = [
      for (var level = 0; level <= 4; level++)
        tester.getTopLeft(find.byKey(ValueKey('assistChip:$level'))).dy,
    ];
    expect(tops.every((t) => t == tops.first), isTrue,
        reason: 'the segments must sit on one line');
  });

  testWidgets('a selected segment label is picked for contrast on the accent',
      (tester) async {
    // Pure White: the accent is near-white, so a white label would vanish.
    // This is the case that breaks a design which hardcodes its label colour.
    const whiteIndex = 26;
    await pump(
      tester,
      SelectorBody(
        colorIndex: whiteIndex,
        layout: SelectorLayout.segments,
        items: [
          SelectorItem(
              keyValue: 'assistChip:0',
              label: '0',
              tooltip: 'Select assist 0',
              selected: true,
              onTap: () {}),
        ],
      ),
    );

    final label = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('assistChip:0')),
        matching: find.byType(Text)));
    expect(label.style?.color, getColor(whiteIndex).onAccent());
    expect(label.style?.color, Colors.black,
        reason: 'a near-white accent needs a dark label');
  });
}
```

- [ ] **Step 4: Run the tests, verify they fail**

Run: `flutter test test/control_cards_test.dart`
Expected: FAIL to compile — `ControlCard`, `SelectorBody`, `SelectorLayout` and `theme.dart` do not exist yet.

- [ ] **Step 5: Reshape `lib/widgets.dart`**

Add the import `package:superduper/theme.dart`. Keep `SelectorItem` exactly as it is (Task 5 already made `onTap` nullable). Then:

**Delete** `SelectorCard` (lines 23-108). `ControlCard` replaces it, and only `lib/bike.dart` used it.

**Add** the layout enum, above `SelectorItem`:

```dart
/// How a [SelectorBody] lays its choices out.
enum SelectorLayout {
  /// One full-width row per choice. The only safe layout for a list whose
  /// length the rider controls, such as the bike's modes.
  rows,

  /// Equal-width segments on one line. Only for a fixed, small count: five
  /// assist levels always fit, and so can never wrap the way the old chips did.
  segments,
}
```

**Add** the state indicator:

```dart
/// Shows whether a control is on. Deliberately not a Material [Switch]: the
/// whole card carries the tap, and a second gesture inside it would fight the
/// first.
class ControlSwitch extends StatelessWidget {
  const ControlSwitch({super.key, required this.on, required this.accent});

  final bool on;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 24,
      decoration: BoxDecoration(
        color: on ? accent : SDSurface.border,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Align(
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: on ? SDSurface.page : SDSurface.label,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
```

**Add** the card. One widget covers all four sections: a header, and an optional body under it.

```dart
/// A control section: a header with the section's title, its state and its
/// lock, and an optional body of choices under it.
///
/// The card is graphite for every bike. The bike's colour enters only through
/// [colorIndex], and only as an accent on the icon, the switch and the
/// selection inside [body] — see [SDSurface].
class ControlCard extends StatelessWidget {
  const ControlCard({
    super.key,
    required this.title,
    required this.colorIndex,
    this.titleIcon,
    this.active = false,
    this.showSwitch = true,
    this.enabled = true,
    this.onTap,
    this.trailing,
    this.body,
  });

  final String title;
  final int colorIndex;
  final IconData? titleIcon;

  /// Whether the control is on, or holds a selection. Drives the accent.
  final bool active;

  /// Whether the header shows a [ControlSwitch]. False for a section whose
  /// state lives in its [body] instead.
  final bool showSwitch;

  /// False dims everything the bike owns. [trailing] keeps full contrast: a
  /// lock is app state, so it still works while the bike is out of range.
  final bool enabled;

  final VoidCallback? onTap;

  /// The lock button, or nothing for a section that has no lock.
  final Widget? trailing;

  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final accent = getColor(colorIndex).accent();
    final header = Row(
      children: [
        if (titleIcon != null) ...[
          Icon(titleIcon,
              size: 20, color: active ? accent : SDSurface.label),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: SDSurface.text,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        if (showSwitch) ControlSwitch(on: active, accent: accent),
      ],
    );

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: SDSurface.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: SDSurface.border),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Opacity(
                          opacity: enabled ? 1.0 : 0.5, child: header)),
                  // Outside the Opacity on purpose: the lock stays usable, and
                  // has to stay readable, while the bike is out of range.
                  if (trailing != null) trailing! else const SizedBox(width: 8),
                ],
              ),
              if (body != null)
                Opacity(
                  opacity: enabled ? 1.0 : 0.5,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12, right: 8),
                    child: body,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
```

**Add** the body:

```dart
/// The choices inside a [ControlCard], laid out by [layout].
class SelectorBody extends StatelessWidget {
  const SelectorBody({
    super.key,
    required this.items,
    required this.layout,
    required this.colorIndex,
  });

  final List<SelectorItem> items;
  final SelectorLayout layout;
  final int colorIndex;

  @override
  Widget build(BuildContext context) {
    final range = getColor(colorIndex);

    SelectorChip chip(SelectorItem item) => SelectorChip(
          key: ValueKey(item.keyValue),
          item: item,
          layout: layout,
          accent: range.accent(),
          onAccent: range.onAccent(),
        );

    if (layout == SelectorLayout.segments) {
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SDSurface.border),
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) Container(width: 1, height: 44, color: SDSurface.border),
              Expanded(child: chip(items[i])),
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          chip(items[i]),
        ],
      ],
    );
  }
}
```

**Rewrite** `SelectorChip` (lines 110-152) to render either shape. Keep the class name and the bold selected label: `test/pickers_test.dart` finds chips by type and reads that weight.

```dart
/// A single tappable choice inside a [SelectorBody].
class SelectorChip extends StatelessWidget {
  const SelectorChip({
    super.key,
    required this.item,
    required this.layout,
    required this.accent,
    required this.onAccent,
  });

  final SelectorItem item;
  final SelectorLayout layout;

  /// The bike's accent colour.
  final Color accent;

  /// What a label on a solid [accent] fill must be, so a near-white or pastel
  /// accent still carries a readable label.
  final Color onAccent;

  @override
  Widget build(BuildContext context) {
    final selected = item.selected;
    final isSegment = layout == SelectorLayout.segments;

    // Exactly one Text per chip: test/pickers_test.dart reads the chip's label
    // and its weight through a single-Text finder. Draft A's "active" caption
    // on the selected mode row is left out for that reason, and because the
    // accent and the bold label already say which row is active.
    final label = Text(
      item.label,
      overflow: TextOverflow.ellipsis,
      textAlign: isSegment ? TextAlign.center : TextAlign.start,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: selected
                ? (isSegment ? onAccent : SDSurface.text)
                : SDSurface.muted,
            fontWeight: selected ? FontWeight.bold : FontWeight.w400,
          ),
    );

    final Widget content = isSegment
        ? Container(
            height: 48,
            alignment: Alignment.center,
            color: selected ? accent : Colors.transparent,
            child: label,
          )
        : Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: selected ? accent.withAlpha(33) : SDSurface.row,
              borderRadius: BorderRadius.circular(12),
              // A transparent border still takes its line of layout, so a
              // selected row is exactly as tall as an unselected one.
              border: Border.all(color: selected ? accent : Colors.transparent),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? accent : SDSurface.muted,
                ),
                const SizedBox(width: 12),
                Expanded(child: label),
              ],
            ),
          );

    return Tooltip(
      message: item.tooltip,
      child: GestureDetector(
        onTap: item.onTap,
        behavior: HitTestBehavior.opaque,
        child: content,
      ),
    );
  }
}
```

- [ ] **Step 6: Run the new tests, verify they pass**

Run: `flutter test test/control_cards_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 7: Rewrite the four control widgets in `lib/bike.dart`**

Add the import `package:superduper/theme.dart`. Each widget keeps Task 5's `connected` read, and passes it as `enabled` instead of wrapping the card in `Opacity` — the card dims its own contents and leaves the lock alone.

`EnhancedLockWidget`: it now sits in a card header, so drop the left margin and the grey pill, shrink the icon, and give it a tooltip (the driver workflow finds controls by tooltip):

```dart
class EnhancedLockWidget extends StatelessWidget {
  const EnhancedLockWidget({
    super.key,
    required this.locked,
    required this.onTap,
    required this.tooltip,
  });

  final bool locked;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: onTap,
      icon: Icon(
        locked ? Icons.lock : Icons.lock_open,
        color: locked ? SDSurface.text : SDSurface.muted,
      ),
    );
  }
}
```

`EnhancedLightControlWidget`:

```dart
    return ControlCard(
      colorIndex: bike.color,
      title: "Light",
      titleIcon: bike.light ? Icons.lightbulb : Icons.lightbulb_outline,
      active: bike.light,
      enabled: connected,
      onTap: connected ? bikeControl.toggleLight : null,
      trailing: EnhancedLockWidget(
        locked: bike.lightLocked,
        onTap: bikeControl.toggleLightLocked,
        tooltip: 'Lock the light',
      ),
    );
```

`EnhancedModeControlWidget`: keep the `Column` and the iOS speed-switching caption exactly as they are, and keep the `selectedModeId` match by id. Replace the `Row` holding `SelectorCard` and the lock with:

```dart
        ControlCard(
          colorIndex: bike.color,
          title: "Mode",
          titleIcon: Icons.electric_bike,
          showSwitch: false,
          enabled: connected,
          trailing: EnhancedLockWidget(
            locked: bike.modeLocked,
            onTap: bikeControl.toggleModeLocked,
            tooltip: 'Lock the mode',
          ),
          body: SelectorBody(
            colorIndex: bike.color,
            layout: SelectorLayout.rows,
            items: [
              for (final mode in bike.selectableModes)
                SelectorItem(
                  keyValue: 'modeChip:${mode.id}',
                  label: mode.name,
                  tooltip: 'Select mode ${mode.name}',
                  selected: mode.id == selectedModeId,
                  onTap: connected ? () => bikeControl.selectMode(mode.id) : null,
                ),
            ],
          ),
        ),
```

`EnhancedAssistControlWidget`: the same shape, with `layout: SelectorLayout.segments` and the 0-4 loop unchanged. Drop its outer `Row` and the trailing lock, and pass the lock as `trailing` with the tooltip `Lock the assist`.

Leave `active` at its default on both Mode and Assist. In draft A only the light icon takes the accent, and only while the light is on; the mode and assist icons stay `SDSurface.label`, because the accent inside their body already marks the selection.

`EnhancedBackgroundLockWidget`: keep the `Column` and its battery caption. Swap the `DiscoverCard` for:

```dart
        ControlCard(
          colorIndex: bike.color,
          title: "Background Lock",
          titleIcon: Icons.phonelink_lock,
          active: bike.modeLock,
          onTap: () async { /* the existing permission body, unchanged */ },
        ),
```

Do not pass `enabled` here: Background Lock is app state and works while the bike is out of range, exactly like the lock buttons.

- [ ] **Step 8: Restyle the page around the cards**

In `lib/bike.dart`, `BikePage.build`:

1. `Scaffold(backgroundColor: SDSurface.page)` and `SliverAppBar(backgroundColor: SDSurface.page)`, and the `flexibleSpace` background `Container(color: SDSurface.page)`.
2. Strip the `Container` wrappers from the back and settings `IconButton`s: both paint `Colors.black.withAlpha(51)` on a black page, which draws an invisible box. Keep the icons and the tooltips, and use `SDSurface.text` for the colour.
3. In the name header, put the bike's gradient in one dot before the name — the one place the full gradient survives:

```dart
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [
                              getColor(bike.color).start,
                              getColor(bike.color).end,
                            ],
                            begin: Alignment.bottomLeft,
                            end: Alignment.topRight,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
```

   Wrap it and the existing name `Column` in a `Row` with `crossAxisAlignment: CrossAxisAlignment.start`, and give the dot a `Padding(top: 6)` so it sits on the name's first line.
4. Quiet the help button down: replace the `ElevatedButton.icon` and its blue `0xff4A80F0` fill with a `TextButton.icon` whose `foregroundColor` is `SDSurface.muted`, label `Help & tips` in sentence case. Keep the same URL and `LaunchMode.externalApplication`.
5. Add the `colors.dart` import if the analyzer asks for it.

- [ ] **Step 9: Run the whole suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean. Two groups matter most:
- `test/pickers_test.dart` — all 8 tests must pass **unchanged**. They are the proof that the reshape kept the keys, the labels, the tooltips, the chip count and the bold selected label. If one fails, fix the widget, not the test.
- Task 5's three `a disconnected bike ignores ...` tests must still pass. The light one taps `find.text('Light')`, which is still the card's title.

- [ ] **Step 10: Commit**

```bash
jj commit -m "feat: rebuild the bike page controls on neutral cards

Every card was painted with the bike's gradient, and the mode and
assist chips wrapped onto extra rows. Cards are now graphite for every
bike, the bike's colour is an accent plus one identity dot, mode is a
row per mode, and assist is five segments that cannot wrap."
```

---

### Task 8: Move the select page onto the same tokens (goal 2)

**Why.** `DiscoverCard` still paints the saved and discovered bike rows with the full gradient (`lib/select_page.dart:280` and `:369`). Left alone, the first screen stays loud while the bike page is calm. No draft exists for this screen's layout, so only the colours change here: same card surface, same accent rule, same layout.

**Files:**
- Modify: `lib/widgets.dart` (`DiscoverCard`)
- Test: none new — the card carries no logic. Step 3 checks it in the running app.

- [ ] **Step 1: Restyle `DiscoverCard`**

Keep every parameter and the whole layout. Replace the gradient `BoxDecoration` with `SDSurface.card` plus a `SDSurface.border` hairline, and derive the foreground from the tokens rather than from `fontColor()`:

- title: `SDSurface.text`
- subtitle and metric: `SDSurface.label`
- `titleIcon`: `getColor(colorIndex).accent()` when `selected`, else `SDSurface.muted`
- `selected == false`: keep the card surface and drop the accent, instead of the current grey-gradient swap

Then delete the now-unused `startColor`/`endColor`/`textColor` locals so the analyzer stays clean.

- [ ] **Step 2: Run the suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean.

- [ ] **Step 3: Commit**

```bash
jj commit -m "feat: paint the select page cards on the neutral surface

The bike page moved to graphite cards with an accent. The select page
kept full-gradient rows, which left the two screens inconsistent."
```

---

### Task 9: End-to-end visual check of the redesign

**Why.** Tasks 7 and 8 change how the app looks, which no widget test judges. Check it against the running app with fake bikes — no hardware — using the "Driving the UI" tooling in CLAUDE.md.

- [ ] **Step 1: Start the driver target**

Run: `flutter run -d linux -t test_driver/app.dart --print-dtd`
Connect the Dart MCP to the printed DTD URI and call `set_frame_sync` with `enabled: false`. Open the debug page and create two fake bikes.

- [ ] **Step 2: Check the two screens**

Give the two fake bikes different colours through the edit sheet: one saturated (Fiery Fuchsia) and one pastel or near-white (Cotton Candy, or Pure White). Then confirm on each bike's page:
- No card carries a gradient. The only gradient on the page is the dot next to the bike's name.
- Every label stays readable on the pastel bike, above all the selected assist segment.
- The five assist segments sit on one line, and the mode rows are full width. Nothing wraps.
- Each lock sits in its card's header, on the same line as the title, and the cards run the full width of the page.
- Light, Mode, Assist and Background Lock all fit without scrolling on the default window size. Draft A is the compact draft; if the page scrolls here, report it rather than shrinking the tap targets below 44 dp.

- [ ] **Step 3: Check the disconnected state**

Disconnect the fake bike. Light, Mode and Assist must dim and ignore taps (Task 5), while the three locks and Background Lock stay at full contrast and still respond.

- [ ] **Step 4: Report**

Record the observations, with a screenshot of each of the two bike pages, in the task report. If a check fails, stop and fix before closing the plan.

---

### Task 10: The pin state model (goal 3)

**Why.** Goal 3 needs three things the model cannot express: a padlock with three states instead of two, the value each padlock pins, and what the bike itself last reported. The full design, including the reasoning behind each rule, is `scratch/lock-startup/design.md` — read it before starting. This task is the model only; nothing changes behaviour yet.

**Files:**
- Modify: `lib/models.dart` (`BikeState`, ~line 410-430)
- Test: `test/models_test.dart`

**Interfaces:**
- Produces: `enum PinState { open, startup, locked }`.
- Produces on `BikeState`: `pinLight`, `pinMode`, `pinAssist` (all `PinState`, default `open`); `startupLight` (`bool?`), `startupModeId` (`String?`), `startupAssist` (`int?`); `lastSeen` — the bike's own last reported `(assist, light, wire)`, nullable as a group.
- Removes: `modeLocked`, `lightLocked`, `assistLocked`. `modeLock` and `modeLockAuto` stay for now — Task 13 deletes them with the feature, so Background Lock keeps working between the two tasks.

- [ ] **Step 1: Write the failing migration tests**

`bikes.json` files in the wild carry the old booleans. Add to `test/models_test.dart`: a `BikeState` decoded from JSON with `"modeLocked": true, "lightLocked": false` comes back with `pinMode == PinState.locked` and `pinLight == PinState.open`; a state with no `lastSeen` key decodes to `lastSeen == null`. (The `"modeLock"` migration test belongs to Task 13, which deletes that field.) Assert defaults on a fresh `BikeState.defaultState(id)`: every pin `open`, every startup value null, `lastSeen` null.

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/models_test.dart --name "pin"`
Expected: FAIL to compile — `PinState` does not exist.

- [ ] **Step 3: Change the model and run codegen**

Add the enum and the fields, delete the three old padlock booleans. Keep `modeLock` and `modeLockAuto` untouched: Task 13 deletes them with the feature. Keep `@JsonKey` names for the migration where a rename would otherwise drop a saved value. Then:

Run: `dart run build_runner build`
Expected: `models.freezed.dart` and `models.g.dart` regenerate cleanly. Never hand-edit either.

- [ ] **Step 4: Fix every call site the compiler names**

`flutter analyze` will list them: `bike.dart` (`toggleLightLocked`, `toggleModeLocked`, `toggleAssistLocked`, the lock reads in `updateStateDataNow` and `_needsBikeTruth`), `widgets.dart`, `edit_bike.dart` if it touches locks, and the tests. `toggleBackgroundLock` and `_syncKeepAlive` read only `modeLock`, which this task keeps, so they do not change here. At this step keep behaviour identical: `PinState.locked` does exactly what `true` did, and `PinState.startup` behaves as `open` for now. Tasks 11-14 give the new states their meaning.

- [ ] **Step 5: Run the suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean. The Background Lock tests still pass here; Task 13 deletes them with the feature.

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat: give the padlocks three states in the model

A padlock could only be open or locked, and nothing recorded the value
it pins or what the bike last reported. No behaviour changes yet:
locked still forces and startup still behaves as open."
```

---

### Task 11: Give the reconnect its timeouts and its ladder (goal 3)

**Why.** `connect()` passes no timeout (`repository.dart:298`), so it takes flutter_blue_plus's 35 s default, and the `_connecting` guard (`repository.dart:285`) drops every retry while that attempt hangs. So the real interval after a failed attempt is up to 35 s, not the 10 s the timer promises — which is why the 2026-08-07 ride log has 38 s, 52 s and 98 s outages. A switching mode limits nothing for that whole window, so this is a safety fix, not only a latency one. Independent of the pin work: worth doing on its own.

**Files:**
- Modify: `lib/repository.dart` (`connect` ~line 298, `_reconnectTimer` ~line 184)
- Test: `test/` — see Step 3 for what is testable without a radio.

**Interfaces:**
- Produces: `_probeTimeout` (3 s), `_retryTimeout` (5 s), and a rung ladder `[2, 2, 5, 5, 10]` seconds capped at 10 s, reset on every successful connect.

- [ ] **Step 1: Pass explicit timeouts**

Give `_device.connect` `timeout: _probeTimeout` on the immediate attempt and `timeout: _retryTimeout` on ladder attempts. Also bound the `await _device.connectionState.where(...).first` at `repository.dart:300` — it has no timeout today and can hang forever, holding `_connecting` with it.

- [ ] **Step 2: Replace the fixed timer with the ladder**

Replace `Timer.periodic(const Duration(seconds: 10))` with a self-rescheduling timer that walks the rungs and then stays at 10 s. Keep all three existing gates exactly as they are: `_shouldAttemptConnect`, the `autoReconnect` setting, and the adapter-state check that commit `7d499eb8` added. **The ladder never gives up** while `autoReconnect` is on — there is no terminal state.

- [ ] **Step 3: Test what can be tested**

The ladder is a timer over a real radio, so a unit test cannot observe it end to end. Cover the part that is pure, the way `test/reconnect_test.dart` already covers `shouldAutoReconnect` and `shouldAttemptConnect`: extract the rung sequence into `Duration rungFor(int attempt)` and add a group for it in that file — rungs in order, capped at 10 s, and `rungFor(0)` after a reset. Those existing gate tests must keep passing untouched; this task changes the cadence, not the gates. Note in the task report that the cadence itself is verified in Task 15.

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean.

- [ ] **Step 4: Commit**

```bash
jj commit -m "fix: bound the connect attempt and back off in steps

connect() used the 35 s default timeout and the _connecting guard drops
retries while an attempt hangs, so a failed attempt blocked the next one
for up to 35 s. The ride log shows outages of 38 s, 52 s and 98 s, and a
switching mode limits nothing while it is disconnected."
```

---

### Task 12: Detect the power cycle and apply the pinned values (goal 3)

**Why.** A Startup pin has to be applied when a ride starts, and the bike offers no boot flag. The rule is a comparison, not a timer: the bike was power-cycled when it reports values it did not report last time we read it. Read `scratch/lock-startup/design.md` section 4 first — it explains why comparing against app *intent* instead of the last *read* would have fired about 9 times in a single logged ride.

**Order.** After Tasks 10 and 11.

**Files:**
- Modify: `lib/bike.dart` (`updateStateDataNow` ~line 355, `_onConnectionState` ~line 157, `_reassertAfterReconnect` ~line 200)
- Test: `test/bike_test.dart`

**Interfaces:**
- Consumes: `BikeState.lastSeen` from Task 10.
- Produces: the `lastSeen` write, on every successful read and **never** on a write; and the pin application on a power-cycle verdict.

- [ ] **Step 1: Write the failing tests**

In `test/bike_test.dart`, using the existing `FakeBikeStore` harness:

1. *A dropout applies nothing.* Open a bike, let a read land, arm a startup pin, drop and restore the connection with the fake bike's bytes unchanged. The bike's mode must not change.
2. *A power cycle applies the pins.* Same, but change the fake bike's reported bytes while disconnected. On reconnect the pinned mode, light and assist must be written.
3. *An unconfirmed write is not a power cycle.* Set the app's intent to a value the bike never confirmed (the case from the ride log), then reconnect with the bike reporting what it last truly reported. Nothing may be applied.
4. *A switching mode's cap wire is not a power cycle.* With a switching custom mode selected, reconnect with the bike on its cap wire. `assertsWire` must absorb it and nothing may be applied.
5. *No record means apply.* With `lastSeen == null` and a startup pin armed, the first read applies the pins.
6. *Open and Locked are untouched.* An `open` pin applies nothing; a `locked` pin keeps forcing as it does today.

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/bike_test.dart --name "power cycle"`
Expected: FAIL — nothing applies the pins yet. Check test 3 fails for the right reason and not because the harness cannot express an unconfirmed write.

- [ ] **Step 3: Implement**

Record `lastSeen` in `updateStateDataNow` at the point the read is parsed (`bike.dart:355`), from the bike's bytes only. Place the `lastSeen` update and the power-cycle comparison together, **after** Task 2's pending-write gate: a read the gate skips must neither update `lastSeen` nor run the comparison, or a pending write would consume the power-cycle signature and the pins would never apply. Compare the fresh read against the stored `lastSeen`, with the wire normalised through `assertsWire`. On a difference, apply each pin that is `PinState.startup`, once per outage. Keep `_reassertAfterReconnect` doing its existing job either way.

- [ ] **Step 4: Run the suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass. Watch the `wire verdict in the poll` group: it must be unaffected, because `lastSeen` is a new record and not a change to the verdict.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat: apply the pinned values when the bike was power-cycled

A ride starts on the pinned mode, light and assist. The bike offers no
boot flag, so a power cycle is detected by comparing the fresh read
against the last value the bike itself reported — never against what the
app intended, which a write lost to a disconnect makes differ."
```

---

### Task 13: Derive the background service and delete the Background Lock control (goal 3)

**Why.** Two things keep the control loop running and both hang off one switch: `ref.keepAlive()` (`bike.dart:284`) is gated on `modeLock || needsSpeedSwitching`, and the foreground service on `modeLock` alone. So a rider who locks a value and never finds Background Lock loses enforcement as soon as the page is popped or the phone is pocketed, silently. Deriving the service from what actually needs enforcing fixes that bug and removes a control that asks the rider to understand Android foreground services.

**Order.** After Tasks 7 and 10.

**Files:**
- Modify: `lib/bike.dart` (`_syncKeepAlive` ~line 283, `ForegroundNotificationWrapper` use ~line 855; delete `toggleBackgroundLock`, `_enableAutoBackgroundLock`, `EnhancedBackgroundLockWidget`)
- Modify: `lib/models.dart` (delete `modeLock` and `modeLockAuto` from `BikeState`) — this changes `@freezed` fields, so this task **must** run `dart run build_runner build`
- Test: `test/bike_test.dart`, `test/models_test.dart`

- [ ] **Step 1: Write the failing tests**

The service condition follows state: it is on when a switching mode is selected **or** any pin is `PinState.locked`, and off otherwise. Assert all four combinations through a testable predicate rather than through the plugin. A `PinState.startup` pin alone must **not** turn it on — that is the deliberate trade in the design.

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/bike_test.dart --name "background"`
Expected: FAIL — the condition still reads `modeLock`.

- [ ] **Step 3: Implement**

Derive both layers from `needsSpeedSwitching || anyPinLocked`. Delete `toggleBackgroundLock`, `_enableAutoBackgroundLock` and `EnhancedBackgroundLockWidget`, and the permission requests move to the moment a pin reaches `locked` or a switching mode is selected. Delete `modeLock` and `modeLockAuto` from `BikeState` (including the auto-lock hand-off in `writeStateData`, ~line 474) and run `dart run build_runner build`. Add the migration test: a saved `"modeLock": true` decodes without error and without the field — a rider who had it on gets the service back automatically wherever it was doing something. Replace the card with a read-only status line: on Android, what is being kept active and that it uses battery; on iOS, that locks and speed limiting only work while the app is open. Delete the Background Lock tests with the feature, and keep the iOS speed-switching caption.

- [ ] **Step 4: Handle a refused notification permission**

Without the permission the service cannot run, so a `locked` pin cannot be enforced in the background. Show the pin as degraded rather than pretending it works. This edge exists today and is unhandled; do not leave it unhandled here.

- [ ] **Step 5: Run the suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean.

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat: run the background service when something needs enforcing

Locking a value only kept working if the rider also found Background
Lock, which silently dropped enforcement as soon as the page was popped.
The service now follows the locks and the switching modes that need it,
so the button has no job left."
```

---

### Task 14: The three-state padlock and its badges (goal 3)

**Why.** The pin states need a control and a visible mark, or a value that is pinned is invisible. Draft A's cards from Task 7 carry them. The mockup is batch 5 of the drafts artifact; `scratch/lock-startup/design.md` section 1 lists the three badge shapes and why they differ.

**Order.** After Tasks 7, 10 and 13.

**Files:**
- Modify: `lib/widgets.dart` (`EnhancedLockWidget` becomes a three-state control; `ControlCard` gains a header badge slot; `SelectorChip` gains a badge)
- Modify: `lib/bike.dart` (the three control widgets)
- Test: `test/control_cards_test.dart`, `test/pickers_test.dart`

- [ ] **Step 1: Write the failing widget tests**

Tapping the padlock cycles open → startup → locked → open. The icon is `Icons.lock_open`, `Icons.push_pin`, `Icons.lock` in that order, and each state carries its own tooltip so the state is announced and not only coloured. With a startup pin armed: the pinned mode row shows a `START` badge, the pinned assist segment shows its marker and the "Starts at N" line, and the light header shows `STARTS ON` or `STARTS OFF`. With every pin open, none of those appear.

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/control_cards_test.dart`
Expected: FAIL — the padlock is still a toggle.

- [ ] **Step 3: Implement**

Arming `startup` captures the currently selected value into the matching `startup*` field — that is what makes the picker unnecessary. Do not add a long-press to re-aim the badge; the design defers it deliberately. Keep every existing `ValueKey` and tooltip on the chips, so `test/pickers_test.dart` keeps passing unchanged, and keep exactly one `Text` per chip: the badge must be a sibling of the chip or a non-`Text` widget, or the single-`Text` finders in that file break.

- [ ] **Step 4: Run the suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass. `test/pickers_test.dart` must pass **unchanged**.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat: pin a value with the padlock, and show what is pinned

The padlock now cycles open, startup and locked. Arming startup captures
the selected value, so a ride can start on a mode other than the one
being ridden, and the pinned value is marked where it lives."
```

---

### Task 15: End-to-end check and the hardware measurement (goal 3)

**Why.** Tasks 11-14 change reconnect timing and a behaviour that only a real bike can trigger. One number is still unmeasured: how long after the switch goes back on the bike starts advertising again. It decides whether the 3 s probe separates a power cycle from a dropout.

- [ ] **Step 1: Fake bikes first**

Run: `flutter run -d linux -t test_driver/app.dart --print-dtd`, connect the Dart MCP, `set_frame_sync` false. Check the padlock cycles through three states, the badges appear on the pinned values, the Background Lock card is gone, and the status line says the right thing.

- [ ] **Step 2: Measure a real power cycle**

On hardware, with a startup pin armed: switch the bike off, count 5 s, switch it on. From the log record the gap from disconnect to reconnect, whether the probe or a ladder rung won it, and whether the pinned values were applied. Repeat with a switching custom mode selected, to exercise the wire normalisation. Use a current build — the `[$id]` prefix from commit `7d499eb8` makes per-bike attribution possible, which the 2026-08-07 log lacks.

- [ ] **Step 3: Confirm a dropout applies nothing**

Walk out of range with the bike still on until it disconnects, then walk back. The pinned values must **not** be applied, and the log must show the comparison finding no change.

- [ ] **Step 4: Retune and report**

If the probe loses to a real power cycle, adjust `_probeTimeout` rather than the detection rule — the rule does not depend on it. Record the measured numbers in the task report, and note whether assist, light and wire all reset on this bike.

---

### Task 16: Let a throttle custom mode go above 32 km/h (goal 4)

**Why.** `customLimitMaxThrottle = 32` (`models.dart:185`) stops a rider asking for a throttle mode above 32 km/h, and `effectiveLimitKmh` clamps a hand-edited file to the same. The reason given is that above 32 the only profiles with a throttle are the unlimited ones, and `baseProfileFor` refuses to return an unlimited profile. But the bike's off-road profile does support throttle, so the restriction is wrong: the mode is possible, it just has to ride an unlimited base and let the app hold the limit.

**Mapping, confirmed against the table.** `firmwareProfiles` (`models.dart:59`) is indexed by the absolute wire byte, and EU natives are wires `[4, 5, 6, 7]` (`models.dart:458`), so the rider-facing EU numbering is wire = 3 + EU mode:
- **EU mode 4 = wire 7**, `OFFROAD`, unlimited, throttle. Already aliased as `chWireOffroad`.
- **EU mode 3 = wire 6**, `MODE 3`, cap 45, no throttle.

**What this changes, exactly.**
1. A **throttle** mode above 32 km/h gets an unlimited base: US off-road wire 3 on a US bike, EU off-road wire 7 on an EU or CH bike. No capped profile in the table pairs a throttle with a cap over 32, so an unlimited base is the only way to build this mode.
2. On an EU or CH bike, a **no-throttle** mode gets wire 6 instead of wire 2 where the two tie; a US bike keeps wire 2. They tie at cap 45, so this affects limits 36-45 only; below that the smallest-cap rule already picks a single profile and nothing changes for any region.

**Order.** After Task 1, which rewrites the same wire helpers.

**Files:**
- Modify: `lib/models.dart` (`customLimitMaxThrottle` ~line 185, `effectiveLimitKmh` ~line 204, `baseProfileFor` ~line 80, `capProfileFor` ~line 110, `_wirePairFor` ~line 130)
- Modify: `lib/bike.dart` (`_checkSpeedStream`, for the watchdog in Step 5)
- Modify: `lib/edit_bike.dart` (the limit slider's ceiling, and the warning in Step 6)
- Test: `test/models_test.dart`, `test/bike_test.dart`

> **Read this before starting.** Today `baseProfileFor` guarantees it never returns an unlimited profile — "asking for a limit must never hand the rider off-road" (`models.dart:79`). That guarantee is a fail-safe: below its limit the bike sits on a profile whose *firmware* holds the limit, so a crashed app, a dead phone or a BLE dropout still leaves a limited bike. This task removes that guarantee for one case, and the limit becomes **app-enforced only**. The 2026-08-07 ride log has dropouts of 4.6 s to 98 s; during any of those, a bike on wire 7 is unlimited. Steps 4 and 5 exist to shrink that window and are the reason this task is more than a clamp change. Do not drop them without asking.

- [ ] **Step 1: Write the failing tests for the profile choice**

In `test/models_test.dart`:
- `baseProfileFor(40, true, region: BikeRegion.eu)` (throttle) returns wire 7, and with `region: BikeRegion.us` it returns wire 3 — an unlimited base either way, never a capped profile.
- `baseProfileFor(45, false, region: BikeRegion.eu)` and `baseProfileFor(40, false, region: BikeRegion.eu)` return wire 6; with `region: BikeRegion.us` both keep wire 2.
- `baseProfileFor(30, false)` still returns wire 0, and `baseProfileFor(30, true)` still returns wire 1 — below the tie nothing moves. No region argument on purpose: the US-bank default must not change these.
- `baseProfileFor(25, false)` still returns wire 4 — the smallest-cap rule is absolute, region breaks ties only.
- A throttle mode at 40 has `base != cap`, so `needsSpeedSwitching` is true and the mode is a dynamic one.
- `CustomMode(limitKmh: 40, throttle: true).effectiveLimitKmh == 40` — no longer clamped to 32.

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/models_test.dart --name "ProfileFor"`
Expected: FAIL — the throttle cases clamp to 32 and the ties pick wire 2.

- [ ] **Step 3: Change the profile selection**

Raise the throttle ceiling to `customLimitMax` and delete `customLimitMaxThrottle` along with the throttle branch in `effectiveLimitKmh`. In `baseProfileFor`, allow an unlimited profile **only** when no capped profile of the requested throttle can hold the limit, and let the bike's bank pick the off-road wire when it happens: 3 on US, 7 on EU or CH.

Make the tie-break region-aware rather than "lowest wire wins": an EU or CH bike takes the EU-bank profile, a US bike keeps the US-bank one. Custom modes are offered for every region (`models.dart:466` builds them unconditionally), so a US bike must not start being sent wire 6 or 7. This means threading `BikeRegion` into `baseProfileFor`, `capProfileFor` and `_wirePairFor`, which today take only the mode — that refactor is the bulk of this task. Default the parameter to the US bank so a missed call site fails safe rather than silently changing a US bike.

Update the two doc comments that state the old guarantees: `baseProfileFor`'s "never unlimited" promise, and `_pairWireFor`'s "least of all an unlimited one" (`models.dart:141`), which is no longer true.

- [ ] **Step 4: Enter such a mode on its cap, not its base**

`initialWireFor` puts a mode on its base wire when it is selected, which for these modes means the bike goes unlimited the moment the rider picks it, before a single speed sample has arrived. Invert it for an unlimited base only: enter on the **cap** profile, and switch to the base once a speed sample below the limit confirms the app is actually watching. The rider loses full assistance for a moment when selecting the mode; in exchange the unlimited profile is only ever on the bike while the app is receiving speed.

Test: selecting a throttle-40 mode writes the cap wire, and the base wire is written only after a below-limit speed sample.

- [ ] **Step 5: Write the cap back when the speed stream dies**

`_checkSpeedStream` already watches for a speed stream that has stopped. Extend it: if samples stop while the bike is riding an unlimited base, write the cap profile. A stalled stream means the app has lost sight of the speed, which is exactly when it must not leave the bike unlimited.

Test: with a throttle-40 mode on its base wire, a speed timeout writes the cap wire.

- [ ] **Step 6: Say so in the editor**

The limit slider's ceiling rises to 45 for a throttle mode. When a rider picks a throttle limit above 32, show a line under the slider saying what it costs: the bike rides its off-road profile below the limit, so this mode only holds its limit while the app is running. Write it plainly, no hedging.

- [ ] **Step 7: Run the suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean. Watch the CH tests closely: `chWireLow` (wire 1, a US-bank profile) is deliberately used by the seeded CH mode, so the region-aware tie-break must not move it.

- [ ] **Step 8: Commit**

```bash
jj commit -m "feat: allow a throttle custom mode above 32 km/h

The off-road profile carries a throttle, so the 32 km/h ceiling was
wrong. Such a mode rides EU off-road below its limit, which means the
app holds the limit rather than the firmware: it enters on its cap
profile and drops back to it when the speed stream stops."
```

---

### Task 17: Name a new custom mode after its speed (goal 5)

**Why.** `_addCustomMode` seeds every new mode with the name `'Custom'` (`edit_bike.dart:211`). A rider who adds two modes gets two rows both called Custom, and the name says nothing about what the mode does. The speed does: a mode limited to 30 km/h should open already called `30 km/h`. The name still belongs to the rider — as soon as they type, the app stops touching it.

**Order.** After Task 16, which edits the same sheet (`_maxKmh`, `_dropoutCaption`) and deletes `customLimitMaxThrottle`. Doing 17 first would make 16 rebase over it for no gain.

**Files:**
- Modify: `lib/edit_bike.dart` (`_addCustomMode` ~line 208, `_CustomModeEditor` / its state ~line 784-830, the name `TextFormField` ~line 896)
- Test: `test/edit_bike_test.dart` (it exists — follow the patterns already in it)

**Interfaces:**
- Produces: `_CustomModeEditor.autoName` (bool) — true only from the add path.
- Produces: `String customModeNameFor(int limitKmh)` in `edit_bike.dart`, returning `'$limitKmh km/h'`. One function, so the seed and the live update cannot drift.

- [ ] **Step 1: Write the failing widget tests**

Open the editor through the add button and assert, with `find.byKey(const ValueKey('customModeNameField'))`:
1. The field opens showing `25 km/h`, not `Custom` (25 is `customLimitMin`, the limit a new mode starts on).
2. Moving the slider to 30 changes the field to `30 km/h`.
3. After typing `Trail` in the field, moving the slider to 35 leaves it as `Trail`.
4. Clearing the field and then moving the slider brings the auto name back — an empty name is untouched again, and the form's `Required` validator never gets a chance to fire.
5. Opening an **existing** mode named `Trail` and moving its slider leaves the name alone. Auto-naming is for new modes only.

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/edit_bike_test.dart`
Expected: FAIL — the field shows `Custom` and never follows the slider.

- [ ] **Step 3: Seed the name from the limit**

In `_addCustomMode`, replace `name: 'Custom'` with `name: customModeNameFor(customLimitMin)`, and pass `autoName: true` into `_showCustomModeEditor` and on to `_CustomModeEditor`. The edit path passes `false`. Pass the flag explicitly rather than guessing from the name — inferring "this looks auto-generated" would rename a mode a rider had deliberately called `30 km/h`.

- [ ] **Step 4: Follow the slider while the name is untouched**

Add `bool _nameEdited = false` to the state, and give the name `TextFormField` an `onChanged` that sets `_nameEdited = value.trim().isNotEmpty`. Then have `_setLimit` call one private `_syncAutoName()` that writes `customModeNameFor(_limitKmh)` into the controller when `widget.autoName && !_nameEdited`. Only `_setLimit` needs the hook: Task 16 deleted the throttle clamp, so `_setThrottle` can no longer change the limit.

Use the field's `onChanged`, **not** a listener on the controller: `onChanged` fires only for user edits, while a controller listener also fires when `_syncAutoName` writes the text, which would mark the name edited on the first slider move and kill the feature.

- [ ] **Step 5: Check it in the running app**

Run: `flutter run -d linux -t test_driver/app.dart --print-dtd`, open a fake bike's settings, add a custom mode. The name must track the slider, stop tracking the moment you type, and the saved mode must appear in the Mode card under its speed name.

- [ ] **Step 6: Run the suite and the analyzer**

Run: `flutter test && flutter analyze`
Expected: all pass, analyzer clean.

- [ ] **Step 7: Commit**

```bash
jj commit -m "feat: name a new custom mode after its speed

Every new mode was called Custom, so two of them were indistinguishable
in the mode list. A new mode now follows its limit until the rider types
a name of their own."
```

---

## Self-review notes

- Finding 6 (oscillation) has no task — the user decided to keep the behavior.
- Task ordering that matters inside goals 1-2: Task 2 reuses `debugHandleSpeedSample` from Task 1; Tasks 3 and 4 edit the same timer body, in that order; Task 7 must follow Task 5, because both rewrite the three control widgets and Task 7 carries Task 5's connection gate forward. The goal 3-5 orderings are listed in the notes below and in each task's **Order** line.
- Only Tasks 10 and 13 touch `@freezed` fields; both run `dart run build_runner build`. No `@riverpod` provider signature changes anywhere.
- The `GATT_CONNECTION_TIMEOUT` retry hunt (3/min against a switched-off bike) is by design for switching modes and is out of scope.
- Task 6 stays the end-to-end check for the timer work (Tasks 1-4); Task 9 is the end-to-end check for the redesign (Tasks 7-8); Task 15 is the end-to-end check for the pin work (Tasks 10-14). None replaces another.
- Goal 3 ordering: Task 10 (model + codegen) comes first and everything depends on it. Task 11 is independent of the rest and worth landing early — it is a safety fix on its own. Tasks 13 and 14 also need Task 7, because they edit the cards it builds.
- Goal 3 keeps two limits on purpose, both recorded in the design doc: changing the mode with the bike's own buttons while disconnected looks like a power cycle and gets overwritten, and a power cycle while the app is not running is never caught up. Do not "fix" either without asking.
- Task 16 is the only task that lets an unlimited profile become a base wire. It must run after Task 1, and its Steps 4 and 5 are the fail-safes that pay for it — a reviewer who removes them turns the mode into "unlimited until the app says otherwise, with no recovery".
- Task 16 needs `BikeRegion` threaded into the wire helpers, because custom modes exist for every region and a US bike must not be sent EU-bank wires. `chWireLow` (wire 1) is a US-bank profile used on purpose by CH bikes, so "prefer the EU bank" is a tie-break only, never a blanket rule.
- A `PinState.startup` pin deliberately does not start the foreground service. Only `locked` pins and switching modes do. Adding startup would mean a permanent notification to catch one moment per ride.
- Task 7 refines Task 5 rather than repeating it: Task 5 wraps a whole card in `Opacity`, which would also dim the lock inside the new header. Task 7 passes `enabled` into `ControlCard`, which dims what the bike owns and leaves the lock readable. Task 5's three tests still pass, because the taps are still ignored.
- Task 7 leaves draft A's "active" caption on the selected mode row out on purpose. Two `Text` widgets inside one keyed chip would break the single-`Text` finders in `test/pickers_test.dart`, and the accent plus the bold label already mark the row.
- Draft A's assist segments are 48 dp tall and its mode rows 52 dp, both above the 44 dp the platforms ask for. Do not shrink them to win height; report instead (Task 9, Step 2).
- No task changes `lib/models.dart`'s packet encoding or the mode data, so a bike's saved colour index keeps its meaning and no migration is needed.
