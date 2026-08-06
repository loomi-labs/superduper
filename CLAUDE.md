# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

SuperDuper is a Flutter app (Android/iOS) that controls Super73 ebikes over Bluetooth LE — an alternative to the official app. No backend; all state is local.

## Commands

```sh
make dev                      # flutter run --hot -d macos (dev happens on macOS desktop)
make watch                    # build_runner watch + dev, in parallel
dart run build_runner build   # regenerate freezed/riverpod/json code (make build-runner)
flutter analyze               # lint (flutter_lints + riverpod_lint)
flutter test                  # run tests
flutter test test/utils_test.dart   # run a single test file
make build-android            # release appbundle + apk
make build-ios                # release ipa
make release                  # tag.sh (commit+tag from pubspec version) then full build
make upgrade                  # flutter pub upgrade --major-versions
```

Release flow (from README): bump `version:` in pubspec.yaml, don't commit, run `make release` — tag.sh commits, tags `v<version>`, pushes, and prints the GitHub release-notes URL. Artifacts are uploaded manually to Play Console / Transporter.

## Code generation

The project uses freezed (data classes), json_serializable, and riverpod_generator. Generated files (`*.g.dart`, `*.freezed.dart`) are committed but must never be edited by hand — after changing any `@freezed` class or `@riverpod` provider, run `dart run build_runner build`. The analyzer excludes `**/*.g.dart`.

## Architecture

All source lives flat in `lib/`. State management is Riverpod (annotation/codegen style). The layering, top to bottom:

- **`main.dart`** — entry point. Requests platform-specific BLE/location permissions, then shows `BikeSelectWidget`. On macOS permissions are skipped (dev-only target; there is no macOS release).
- **`select_page.dart`** — scans for bikes, lists saved + discovered ones, navigates to `BikePage`. Selecting a bike stores it as `currentBike` in settings.
- **`bike.dart`** — the core. The `Bike` riverpod notifier (keyed by device id) owns the control loop: polls bike state every 5s (debounced around writes), and enforces "locked" settings — if a locked value (light/mode/assist) differs from what the bike reports, it writes the locked value back. Also contains `BikePage` UI and the Android-only Background Lock, implemented as a `flutter_foreground_task` foreground service that keeps the app (and the lock loop) alive when the phone is locked.
- **`repository.dart`** — Bluetooth layer over flutter_blue_plus. `ConnectionHandler` (per device id) manages connect/auto-reconnect (10s retry timer) and exposes read/write; `BluetoothRepository` does scanning (keyword-filtered for SUPER73 devices) and raw characteristic reads/writes.
- **`models.dart`** — `BikeState` (freezed): encodes/decodes the BLE packet. Reading state means writing `[3, 0]` to the register-ID characteristic then reading the register characteristic; writes send `[0, 209, light, assist, mode, 0...]`. EU-region bikes offset mode values by +4 (`BikeRegion` handles this).
- **`services.dart`** — BLE service/characteristic UUIDs for the bike's GATT profile.
- **`db.dart`** — persistence: plain JSON files (`bikes.json`, `settings.json`) in the app documents directory, wrapped in `keepAlive` riverpod notifiers (`BikesDB`, `SettingsDB`).
- **`utils/logger.dart`** — global `log` (SDLogger). Log with a tag constant: `log.d(SDLogger.bike, '...')`; tags are `bluetooth`, `bike`, `ui`, `db`, `general`. Debug-level logs are stripped in release.
- **`debug.dart`** — debug page that fabricates bikes with random MAC addresses for UI work without hardware.

`docs/` is a separate Hugo site (`make docs`), unrelated to the app code.

## Driving the UI (Flutter Driver — "Playwright for Flutter")

For agent-driven end-to-end testing against fake bikes, no hardware needed:

```sh
flutter run -d linux -t test_driver/app.dart --print-dtd
```

`test_driver/app.dart` enables the Flutter Driver extension. Connect the Dart MCP to the
printed DTD URI (`dtd` tool → `connect`), then drive the app with `flutter_driver_command`
(tap/scroll/waitFor/get_text) and inspect with `widget_inspector`. Two gotchas: call
`set_frame_sync` with `enabled: false` first (the scan spinner animates forever and blocks
synced commands), and find widgets by the real text/tooltips/keys from `get_widget_tree` —
debug-page fake-bike rows are keyed by device id (`ByValueKey`). Simulate speed with each
fake bike's slider; watch BLE traffic in the `flutter run` log (`[Bluetooth]` lines).
