# Boot Calibration and Power-Cycle Detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development or superpowers:executing-plans.
> This is a living plan. Append new tasks before the "Notes" section and
> continue the numbering.

**Goal 1 (Tasks 1-4):** Detect a power cycle by comparing against a measured,
per-bike boot signature instead of assumptions about the firmware. A one-time
guided calibration records what the bike's settings register really reports
after a power-on, classifies each byte as *resets-to-constant* (usable) or
*comes-back-unchanged* (persisted, unusable), and saves the result. Detection
then uses only the usable bytes.

**Why.** The 2026-08-11 hardware logs showed: the bike boots with assist 0, a
~2 s light transient, and its mode reset to the EU boot mode (wire 4) — but
the settings register reported the *pre-outage* assist and light on every one
of 14 verified reconnect first-reads. Assist and light through that register
carry no boot information; only the wire byte demonstrably resets (dropouts in
the 2026-08-07 log preserved wires 1 and 7). Today's detection
(`_isPowerCycle`, `lib/bike.dart:662-682`) forgives the boot wire whenever the
selected mode asserts it, so startup pins never fire for ≤25/30 km/h custom
modes — five real boots went undetected on 2026-08-11. Hardcoding "wire 4 =
boot" would break US bikes and future firmware; measuring per bike does not.

**Goal 2 (Tasks 5-7):** Usability and battery fixes from the 2026-08-11 field
test. Startup pins get an explicit selection state — while a pin is on
`startup`, its card selects the *start* value (tappable offline, since it is
app state) instead of the live value. The Auto-reconnect description shrinks
to what the rider needs. And the reconnect policy follows the toggle:
Auto-reconnect on means the app keeps trying while Bluetooth is on; off means
a dynamic mode gets one finite ladder (~40 s) after a drop and then the app
gives up — instead of today's unconditional forever-hunt (the 2026-08-11 log
shows ~4 h at 4 attempts/min).

**Architecture.** A `BootSignature` freezed model on `BikeState` (nullable —
null means "not calibrated", which is also the migration state for every
existing bike). A calibration controller in `lib/bike.dart` that owns a
write-suppression window (the app currently writes ~200 ms after the first
reconnect read — `_reassertAfterReconnect` and the heal path — which destroys
the evidence; suppression is the heart of this plan). A guide UI (new
`lib/calibration_page.dart` or a dialog flow on `BikePage`). Detection change
in `_isPowerCycle` consuming the signature. Light is ignored entirely.

**Decisions already made (do not revisit):**
- Light is not recorded and not compared — it has a boot transient and the
  register value is untrustworthy.
- Bytes are classified by measurement, never assumed: a byte whose post-boot
  value equals its staged pre-off value is persisted and excluded.
- The residual blind spot is accepted and documented: if the bike sat on the
  boot wire already (e.g. capped at wire 4) before the outage, boot and
  dropout are indistinguishable — detection stays conservative and applies
  nothing.
- The guide is skippable ("Later") and re-runnable from the bike's settings
  sheet. It triggers on a connected bike with `bootSignature == null` and
  speed 0.

## Global Constraints

- `jj` only, never raw `git`. Commit each task. Never `dart format`. Never
  edit `*.g.dart`/`*.freezed.dart`; Task 1 changes `@freezed` models and must
  run `dart run build_runner build`.
- ASD-STE100 for comments and commit messages; comments explain *why*.
- Verify each task with `flutter analyze` (clean except the ledgered
  `repository.dart` info) and the named tests; full suite green (333 today).
- Reuse: `FakeBikeStore` harness, `openBike()`/`settle()` helpers
  (`test/bike_test.dart`), `ConnectionHandler.read/write`
  (`lib/repository.dart:544-577`), `LastSeen` (`lib/models.dart`).

---

### Task 1: The `BootSignature` model

**Files:** `lib/models.dart`, `test/models_test.dart`, codegen.

- `@freezed class BootSignature`: `measuredAt` (DateTime), `bootWire`
  (`int?` — null when the wire did not reset during calibration),
  `bootAssist` (`int?` — null when assist came back persisted), and
  `preOffWire`/`preOffAssist` (the staged values, kept for re-audit).
- `BikeState.bootSignature` (`BootSignature?`, default null). Migration test:
  old `bikes.json` without the key decodes to null; round-trip preserves it.
- No behaviour change. Run `build_runner`. Commit.

### Task 2: The recording window (write suppression + capture)

**Files:** `lib/bike.dart`, `lib/repository.dart`, `test/bike_test.dart`.

- A `_calibrating` guard on the `Bike` notifier. While set:
  `_reassertAfterReconnect`, startup-pin application, poll-adoption writes,
  `_capUnwatchedMode`, and user-tap writes are suppressed (suppressed writes
  are logged, not queued). The two known write-before-read paths
  (`_capUnwatchedMode` inside the 1 s settle; an early speed-sample switch)
  must be covered by the same guard.
- `recordBootWindow()`: reads the settings register at t≈0,1,2,3,5,8 s after
  the reconnect, logging raw bytes with tag `[Calibration]`; one-shot reads
  odometer `[2,2]` and battery `[4,1]` and logs the first raw `[2,3,…]`
  notification frames (currently dropped silently in `_onNotification`,
  `lib/repository.dart:510-514`) — logged only, not stored in the model.
- Returns the settled `(assist, wire)` from the final read.
- Tests: while calibrating, a reconnect issues no `[0,209,…]` write; the
  guard released restores normal reassert; the capture returns the fake
  bike's bytes. Commit.

### Task 3: The guided calibration flow

**Files:** new `lib/calibration_page.dart` (or dialog flow), `lib/bike.dart`,
`lib/edit_bike.dart` (re-run entry), `test/` widget tests.

Workflow, one screen per step, cancellable at every step:
1. **Stage.** With the bike connected and speed 0: write a non-boot state —
   assist 2 and the selected mode's base wire — and confirm the echo read.
   Record it as `preOff*`. (Staging is required: a pre-off state equal to the
   boot state makes classification impossible.)
2. **"Turn the bike off."** Wait for the disconnect event (timeout ~30 s with
   a retry hint).
3. **"Turn the bike on."** The reconnect ladder brings it back (typically
   5-30 s); show progress.
4. **Record** via Task 2's window (10 s, no writes).
5. **Classify and save.** `bootWire = settled wire == preOffWire ? null :
   settled wire`; same for assist. Persist the `BootSignature`; show the
   result plainly ("Your bike resets its mode to X and its assist to Y" /
   "…keeps its assist, so only the mode is used"). If BOTH classify as
   persisted, save the signature with both null and tell the user that
   automatic power-cycle detection is not possible on this bike.
- Trigger: first connected visit to a bike whose `bootSignature == null`
  (covers every migrated bike), plus a "Calibrate power-cycle detection" row
  in the bike settings sheet for re-runs.
- Tests: full flow against `FakeBikeStore` (stage → disconnect → reconnect →
  classify), skip path, both-persisted path. Commit.

### Task 4: Detection consumes the signature

**Files:** `lib/bike.dart` (`_isPowerCycle`), `test/bike_test.dart`,
`scratch/lock-startup/design.md` §4 update.

- New rule, evaluated only when `bootSignature` exists and has at least one
  non-null byte: power cycle ⇔ every usable byte of the fresh read equals the
  signature AND differs from `lastSeen` (wire compared raw here — the
  `assertsWire` absorption stays only for the heal logic, not the pin
  decision). The residual case (lastSeen already equals the signature) is not
  a detection — conservative, documented.
- `bootSignature == null` (never calibrated / skipped): keep today's
  behaviour unchanged.
- Regression tests encode the measured 2026-08-11 scenarios: bike on base
  wire 1 → boot to wire 4 ⇒ pins apply (the case that failed five times);
  capped at wire 4 → dropout ⇒ nothing; OFFROAD wire 7 → boot ⇒ still
  detected. Commit.

### Task 5: A startup pin selects its value (goal 2)

**Why.** Arming a startup pin captures the current value silently, and while
disconnected the value taps are gated off (`onTap: connected ? … : null` at
`lib/bike.dart:1459`, `:1523`, `:1653`), so a rider cannot choose *which*
mode/assist/light the bike should start with — above all not offline, where
the choice is pure app state and needs no bike. The padlock itself already
works offline (`cycle*Pin` → `writeStateData(saveToBike: false)`, no
connection gate).

**Behaviour (user decision, do not revisit):** while a card's pin is
`startup`, that card is in start-selection state:
- A caption appears under the header: mode "Tap the mode the bike starts
  with", assist "Tap the assist level the bike starts with", light "Tap the
  card to choose: light on or off at the start".
- The card's taps set the `startup*` field (`writeStateData(saveToBike:
  false)`) and never the live value. The START / STARTS ON / STARTS OFF
  badges (Task 14 of PLAN.md) follow the target.
- These taps work regardless of connection: pass `enabled: connected ||
  pinIsStartup` into `ControlCard` and bypass the `connected` gate on the
  taps while in this state.
- The live value cannot be changed from that card while its pin is
  `startup` — un-pin first (tap the padlock: the cycle continues to
  `locked`, which ends the selection state; `locked` semantics unchanged).
- Entering `startup` still captures the current value as the initial target
  (offline it captures the cached value — re-aim with one tap if stale).

**Files:**
- Modify: `lib/bike.dart` — the three control widgets (tap targets, caption,
  `enabled` expression) and, if needed, small notifier setters
  (`setStartupMode/Assist/Light`) beside `cycle*Pin` (~line 1025).
- Modify: `lib/widgets.dart` — `ControlCard` gains an optional caption slot
  under the header (dimmed with the body).
- Test: `test/control_cards_test.dart`, `test/bike_test.dart`.

**Protected surface (absolute, as in PLAN.md Tasks 7/14):** every existing
`ValueKey` and tooltip on the chips, exactly one `Text` per chip,
`test/pickers_test.dart` passes UNCHANGED. The existing "a disconnected bike
ignores … taps" tests run with pins `open` and must keep passing — the gate
stays for open and locked pins.

**Tests to write first:** with the mode pin on `startup` and the bike
DISCONNECTED, tapping a mode row changes `startupModeId` and not
`selectedMode`; with the pin on `startup` and the bike CONNECTED, tapping a
row still changes only `startupModeId`; the same pair for assist; a light
card tap flips `startupLight` only; the caption appears in `startup` and is
gone in `open` and `locked`; cycling the padlock to `locked` ends the
selection state.

Verify: `flutter test && flutter analyze`. Commit:
`feat: select the startup value on the card while its pin is startup`.

---

### Task 6: Simplify the Auto-reconnect description (goal 2)

**Why.** The current four sentences (`lib/edit_bike.dart:536-549`) explain
power-cycling semantics and the Connect button. The rider needs one fact:
background reconnect exists and costs battery.

- Replace the description with: "The app runs in the background and connects
  to the bike whenever possible. This can use more battery."
- Keep the checkbox, its `ValueKey`, and the conditional dynamic-mode warning
  (`ValueKey('autoReconnectWarning')`, `lib/edit_bike.dart:552-561`), but
  shorten the warning to: "A dynamic mode is selected, so the app still
  reconnects for it after a drop." (Wording already accounts for Task 7: the
  reconnect is finite.)
- Update any test that asserts the old strings (`test/edit_bike_test.dart`).

Verify: `flutter test && flutter analyze`. Commit:
`docs: say only what auto-reconnect costs`.

---

### Task 7: Reconnect follows the toggle; a forced ladder is finite (goal 2)

**Why.** Today `shouldAutoReconnect` (`lib/repository.dart:30-34`) is
`autoReconnect || needsSpeedSwitching`, and the ladder (PLAN.md Task 11)
retries at the 10 s cap forever — so even with the toggle off, a dynamic mode
hunts a switched-off bike without end. The 2026-08-11 log shows the cost:
~4 hours of attempts at 4/min, stopped only by turning Bluetooth off.

**Behaviour (user decision, do not revisit):**
- **Auto-reconnect ON:** the app keeps trying to connect for as long as the
  Bluetooth adapter is on — the ladder walks its rungs and then stays at the
  10 s cap indefinitely (today's cadence). Adapter off silences it
  completely; adapter on resumes it (the adapter gate from commit `7d499eb8`
  and `_onAdapterState` already do both).
- **Auto-reconnect OFF, dynamic mode selected:** the forced reconnect runs
  the ladder ONCE — 2, 2, 5, 5, 10 s (~40 s wall clock including the 3 s
  probe and 5 s attempts) — then gives up. `needsSpeedSwitching` no longer
  grants endless retries.
- **Auto-reconnect OFF, no dynamic mode:** no automatic attempts, as today.
- Re-arm for the given-up state (reset the rungs and run the finite ladder
  again): the bike page being opened (`build` already connects), the app
  returning to the foreground (add an `AppLifecycleState.resumed` listener if
  none exists — check `main.dart` / `lib/repository.dart`), the Bluetooth
  adapter turning on (exists), the Connect button (exists), and any
  successful connect (rung reset exists).

**Files:**
- Modify: `lib/repository.dart` (`shouldAutoReconnect` splits into
  "may attempt" vs "may attempt forever"; `_onReconnectTick` /
  `_armReconnectTimer` gain the terminal state for the forced-finite case;
  re-arm hooks), possibly `lib/main.dart` (lifecycle observer).
- Test: `test/reconnect_test.dart` — extend the pure-function coverage in the
  file's existing style: toggle on ⇒ never exhausted; toggle off + dynamic ⇒
  exhausted after the 10 s rung; toggle off + static ⇒ no attempt; attempts
  reset on every re-arm trigger. The existing `shouldAttemptConnect`/`rungFor`
  groups pass untouched; the `shouldAutoReconnect` group changes WITH the
  policy — brief-mandated, update it deliberately.

**Safety note to carry into the code comment:** with the toggle off, a
mid-ride outage longer than ~40 s no longer resumes enforcement on its own —
the rider opted out; a bike on an unlimited base wire stays unlimited until a
re-arm trigger fires. With the toggle on, recovery is unbounded as before.

Verify: `flutter test && flutter analyze`; live check with a fake or real
bike that attempts stop after the last rung and resume on page open.
Commit: `feat: stop the reconnect ladder after its last rung`.

---

### Task 8: Hardware validation (user) — closes goals 1 and 2

Runs once, after every implementation task. The user tests; nothing is
dispatched.

1. **Calibration + pins (goal 1):** run the calibration guide on the real
   bike. Then: power cycle with a startup pin aimed at a *different*
   assist/mode → the pins must apply; walk-away dropout → nothing applies;
   capped-at-limit dropout → nothing applies.
2. **Start selection (Task 5):** with the bike disconnected, set the mode pin
   to startup and pick a start mode — the badge must follow the tap, and the
   live mode must not change after reconnecting.
3. **Reconnect policy (Task 7):** with Auto-reconnect OFF and a dynamic mode
   selected, switch the bike off — the log must show the ladder stop after
   its 10 s rung (~40 s, no attempts after); switch the bike on, open the
   bike page → it must reconnect. Then with Auto-reconnect ON, switch the
   bike off — attempts continue at the 10 s cadence; turn Bluetooth off →
   attempts stop; Bluetooth on → they resume.

Record the log and report per check.

---

## Notes

- Later changes append here as new tasks (user has more coming).
- The recording window doubles as a firmware probe: the `[2,2]`/`[4,1]`/raw
  `[2,3]` logging may surface a cleaner boot tell (trip reset, uptime) for a
  future task; the model deliberately does not store it yet.
- The guide delays nothing outside calibration; normal reconnect enforcement
  is untouched when `_calibrating` is off (existing 333 tests must stay
  green, byte-identical behaviour).
