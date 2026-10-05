# CLAUDE.md

This file gives guidance to Claude Code (claude.ai/code) for the code in this repository.

## Project

Superduper CH is a Flutter app that controls Super73 ebikes over Bluetooth LE. It is a fork of blopker/superduper v1 and ships as a separate app: application ID `com.loomilabs.superduperch`, visible name "Superduper CH". The Dart package name stays `superduper` (imports are `package:superduper/...`).

Android and iOS are the release targets. macOS and Linux are desktop targets for development only. The app has no backend. All data is local, in a drift (SQLite) database.

The fork adds these features to upstream:

- The region CH, with custom modes: a speed limit (25 to 45 km/h) with or without throttle, per bike.
- A ride mode controller that switches firmware profiles as the speed crosses the limit.
- An Android foreground service that keeps the Bluetooth link alive while a switching custom mode is selected.
- A release build that refuses the debug certificate.

## Commands

```sh
make dev                      # flutter run --hot on the desktop (macos on Darwin, linux elsewhere)
flutter analyze               # lint (very_good_analysis + signals_lint); must report no issues
flutter test                  # Dart tests
flutter test test/ble/ride_mode_controller_test.dart   # one test file
dart run build_runner build   # regenerate drift code (app_database.g.dart)
dart run drift_dev schema dump lib/src/persistence/app_database.dart drift_schemas/drift_schema_vN.json
dart run drift_dev schema generate drift_schemas/ test/generated/
make build-android            # release appbundle + apk (needs android/key.properties)
(cd android && ./gradlew :app:testDebugUnitTest)   # Kotlin unit tests
```

A release build without `android/key.properties` fails on purpose. For a local test build only, set `ORG_GRADLE_PROJECT_allowDebugSigning=true`. The build then prints a warning that the APK carries the debug certificate.

After a change to a drift table, increase `schemaVersion`, add the migration step, run `build_runner`, dump the new schema version, and generate the test schemas. `test/persistence/schema_test.dart` migrates and validates every schema version to the current one.

## Architecture

The source is in `lib/src`. State is in `signals`. Code uses Dart primary constructors (`const new(...)`) and private named parameters (`required this._bike`).

- `ble/bike_protocol.dart`: the V1 and V2 wire formats. It encodes and decodes the control packet, reads history records, decodes speed telemetry (`[2, 1, lo, hi]`, km/h x 100), and sends the ride-data request.
- `ble/bike_session.dart`: one connection to one bike. It connects, authenticates, reads and writes the configuration, applies set-on-connect values, reconnects, and publishes `speedKmh`.
- `ble/ride_mode_controller.dart`: the selected ride mode of a session. It writes the base or cap wire of a custom mode as the speed crosses the limit, and it publishes `needsBackgroundHold`.
- `ble/active_bike_coordinator.dart`: owns the active session and its ride mode controller, and forwards `needsBackgroundHold` to the hold gateway.
- `domain/ride_modes.dart`: the firmware profile table, custom modes, the base/cap engine, `BikeRegion`, and the seeded CH mode ("25 km/h", throttle on).
- `domain/bike.dart`: bikes, configurations, control patches, and set-on-connect values (`NativeModeRef` or `CustomModeRef`).
- `persistence/app_database.dart`: drift schema v6. The table `bike_custom_modes` holds the custom modes. `installed_data_importer.dart` imports the old `bikes.json` and `settings.json` once.
- `repositories/`: all database access. A region change in `updateBikeDetails` adapts the modes in the same transaction: a CH bike gets the seeded mode, and a set-on-connect wire that the new region does not offer is cleared (on CH it points at the seeded mode).
- `platform/background_hold.dart`: the Android foreground service (flutter_foreground_task). Other platforms have no hold.
- `platform/background_sync.dart` and the Kotlin code in `android/app/src/main/kotlin/com/loomilabs/superduperch`: upstream's native background sync. Byte 5 of each app control write is 1, and the bike sets it to 0 at power-up; the native sync writes only when byte 5 is 0. The MethodChannel name `io.kbl.superduper/background_sync` is a fixed string and does not follow the application ID.
- `features/`: the pages (add bike, bike control, bike settings with the custom mode editor, hardware test, help, home, startup).

## Wire bytes

A V1 mode is the wire byte 0 to 7. The app never adds an offset to it. The region only decides which modes the app offers and the speed unit it shows.

| Wire | Profile | Limit |
| --- | --- | --- |
| 0 | ECO | 32 km/h |
| 1 | TOUR | 32 km/h + throttle |
| 2 | SPORT | 45 km/h |
| 3 | OFFROAD (US) | none, throttle |
| 4 | EPAC | 25 km/h |
| 5 | MODE 2 | 35 km/h |
| 6 | MODE 3 | 45 km/h |
| 7 | OFFROAD (EU) | none, throttle |

US offers wires 0 to 3, EU offers 4 to 7, CH offers 7 and the custom modes. A V2 mode is the preset 0 to 3.

## Background hold

- The hold is on while the selected ride mode is a custom mode that switches (base and cap differ) and the rider wants the link (no manual disconnect, no final failure). Before the bike confirms a mode, the hold follows the set-on-connect custom mode.
- While the hold is on, the app stays connected when it goes to the background. Otherwise the session pauses in the background.
- When the hold ends while the app is in the background, the session pauses.
- The app follows a mode change on the bike only while the link is ready. The wire that the app reads before the set-on-connect write does not change the selection.
- During the write of a mode choice, the hold follows the previous selection. It changes only when the bike accepted the new mode.
- When the foreground service does not start, the app tries again when it goes to the background.
- iOS has no hold. A switching mode stops when the app leaves the foreground, and the control page says so.

## Repository rules

- Version control is jj (colocated with git).
- These files use CRLF line endings: `Makefile`, `analysis_options.yaml`, `pubspec.yaml`, `lib/src/features/add_bike/add_bike_controller.dart`, `lib/src/features/bike_control/bike_control_page.dart`, `lib/src/features/bike_settings/bike_settings_page.dart`, `lib/src/features/hardware_test/bike_hardware_test_controller.dart`, `test/widget/foreground_workflow_test.dart`. `README.md` has mixed line endings. Keep the line endings of each file; new files use LF.
- `plans/` holds the plans for work that is not finished, one folder per topic (`plans/<n>-<topic>/plan.md`). `plans/README.md` gives the rules. `.git/info/exclude` excludes it from version control.
- `docs/superpowers/` holds older local plans and specs. `.git/info/exclude` excludes it from version control.
- `docs/` also holds upstream's design notes and a separate Hugo site (`make docs`).
