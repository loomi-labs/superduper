# CLAUDE.md

This file gives guidance to Claude Code (claude.ai/code) for the code in this repository.

## Project

Superduper CH is a Flutter app that controls Super73 ebikes over Bluetooth LE. It is a fork of blopker/superduper v1 and ships as a separate app: application ID `com.loomilabs.superduperch`, visible name "Superduper CH". The Dart package name stays `superduper` (imports are `package:superduper/...`).

Android and iOS are the release targets. macOS and Linux are desktop targets for development only. The app has no backend. All data is local, in a drift (SQLite) database.

The fork adds these features to upstream:

- The region CH, with custom modes: a speed limit (25 to 45 km/h) with or without throttle, per bike.
- A ride mode controller that switches firmware profiles as the speed crosses the limit.
- An Android foreground service that keeps the Bluetooth link alive while a switching custom mode is selected or the street-legal preference is on.
- The street-legal lock, per bike: a quick restart (off and on within 10 seconds), or 10 minutes parked on a V1 bike, puts the bike into its stock mode and keeps it there.
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
- `ble/bike_session.dart`: one connection to one bike. It connects, authenticates, reads and writes the configuration, applies set-on-connect values, reconnects, publishes `speedKmh`, and decides the street-legal lock at each connect.
- `ble/off_time_meter.dart`: measures the off time of the bike across a link loss, from the auxiliary counter (`0x1581`) and the phone clock.
- `ble/ride_mode_controller.dart`: the selected ride mode of a session. It writes the base or cap wire of a custom mode as the speed crosses the limit, runs the parked fallback timer, and publishes `needsBackgroundHold`.
- `ble/active_bike_coordinator.dart`: owns the active session and its ride mode controller, and forwards `needsBackgroundHold` to the hold gateway.
- `diagnostics/debug_log.dart`: the debug log per bike (`DebugLog`, `DebugLogStore`). See "Debug log".
- `domain/ride_modes.dart`: the firmware profile table, custom modes, the base/cap engine, `BikeRegion`, and the seeded CH mode ("25 km/h", throttle on).
- `domain/bike.dart`: bikes, configurations, control patches, set-on-connect values (`NativeModeRef` or `CustomModeRef`), and the stock mode of the street-legal lock (`defaultStockMode`, `resolveStockMode`).
- `persistence/app_database.dart`: drift schema v8. The table `bike_custom_modes` holds the custom modes. `bike_preferences` holds the street-legal preference, the stock mode and the debug log preference (`debug_log_enabled`). `installed_data_importer.dart` imports the old `bikes.json` and `settings.json` once.
- `repositories/`: all database access. A region change in `updateBikeDetails` adapts the modes in the same transaction: a CH bike gets the seeded mode, and a set-on-connect wire that the new region does not offer is cleared (on CH it points at the seeded mode).
- `platform/background_hold.dart`: the Android foreground service (flutter_foreground_task). Other platforms have no hold.
- `platform/background_sync.dart` and the Kotlin code in `android/app/src/main/kotlin/com/loomilabs/superduperch`: upstream's native background sync. Byte 5 of each app control write is a marker, and the bike sets it to 0 at power-up; the native sync writes only when byte 5 is 0. A bike with the street-legal preference gets no native plan. The MethodChannel name `io.kbl.superduper/background_sync` is a fixed string and does not follow the application ID.
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

## Street-legal lock

The preference "Street-legal on quick restart" is per bike and off by default. The stock mode is a native wire (V1) or preset (V2) per bike. Null means the default: EPAC (wire 4) on EU and CH, ECO (wire 0) on US, preset 0 on V2.

Byte 5 of each control write is a marker. The bike keeps it in the control-history record (`00 d1` on V1, `00 c1` on V2) and sets it to 0 at power-up.

| Byte 5 | Meaning |
| --- | --- |
| 0, or no record | The bike restarted after the last app write. |
| 1 | The app wrote in this power cycle. |
| 2 | The app wrote in this power cycle while the lock was on. |

With the preference on, the session subscribes to the auxiliary counter (`0x1581`, 1 step each second while the bike is on) and reads the marker at each connect:

- Marker 2: the lock stays on. Marker 1 (a dropout): the lock is off.
- Marker 0: the off time is the phone gap minus the counter on time. An off time of 18 s or less (25 s with the phone clock only) is a quick restart: the lock starts, and the session writes the stock mode when the bike reports another mode. An unknown off time is not quick.

During the lock, each control write carries marker 2, the session does not write the set-on-connect mode, and the ride mode controller selects the wire the bike reports. A mode choice in the app or a slow restart ends the lock.

Parked fallback: when the lock is off and the selected mode is not the stock mode, 10 minutes without a speed sample above 0 km/h on a ready link write the stock mode with marker 2 and start the lock. A dropout pauses the timer. At marker 1 the timer continues, and the bike on time of the dropout counts as parked time. While the timer runs, the controller asks the bike for ride data again each time the samples stop, because the bike stops its ride data at a standstill.

A V2 bike sends no speed samples. It has no parked fallback, only the quick restart lock. The settings page says so below the switch.

A mode choice waits for a parked write that runs, so the choice always comes last and ends the lock that the write starts.

At each connect, a marker read that fails twice, or a record shorter than 6 bytes, gives an unknown off time: the lock keeps its state from memory (a running lock stays on and no mode is written, else it stays off). Turning the preference on clears the meter. The meter keeps the counter samples from before the first link loss until the session takes a gap.

Limit: only a connected app can measure the off time. On iOS the lock works only while the app is in the foreground.

## Background hold

- The hold is on while the rider wants the link (no manual disconnect, no final failure) and either the selected ride mode is a custom mode that switches (base and cap differ) or the street-legal preference is on. Before the bike confirms a mode, the hold follows the set-on-connect custom mode.
- While the hold is on, the app stays connected when it goes to the background. Otherwise the session pauses in the background.
- When the hold ends while the app is in the background, the session pauses.
- The app follows a mode change on the bike only while the link is ready. The wire that the app reads before the set-on-connect write does not change the selection.
- The controller decides the selection from the set-on-connect mode once for each new connection. A confirmed write on a settled link does not decide it again.
- During the write of a mode choice, the hold follows the previous selection. It changes only when the bike accepted the new mode.
- When the foreground service does not start, the app tries again when it goes to the background. An error in the start of the service also allows a new start.
- The notification has two texts. While a switching custom mode runs it says "Superduper CH is holding your speed limit". When the hold comes only from the street-legal preference it says "Superduper CH keeps the link to your bike". The text changes while the service runs when the reason changes.
- iOS has no hold. A switching mode and the street-legal lock stop when the app leaves the foreground. The control page says so for a switching mode. The settings page says so for the street-legal lock.

## Debug log

The debug log is per bike and off by default. The rider turns it on in the bike settings. It records the BLE link, the ride mode controller, the street-legal lock, the background hold and the background sync, in Dart and in the native Kotlin code.

- A line looks like `2026-10-08 14:03:12.345+02:00 D g12 lock    marker=0 offTime=6s ... -> lock ON`. The fields are the local time with offset, the source (`D` Dart, `N` native), the session generation (`g<n>`, or `--`), the area, and the facts with the decision after `->`.
- The areas are `app`, `link`, `auth`, `config`, `speed`, `mode`, `lock`, `meter`, `parked`, `hold`, `sync` and `native`.
- The log never holds the authentication key or the challenge response.
- Speed gets no line per sample. It gets a line at start and stop, at a crossing of the limit, and a heartbeat each 5 seconds while the bike moves. The parked timer reset gets one line for each ride. A missing speed stream gets one line, then one line each 5 minutes.
- A message is one line: line breaks in an error text become ` | `.
- `DebugLogStore` (one in `AppServices`) owns the folder `<documents>/debug_logs/`. The coordinator gives it the saved bikes, and it follows the preference. A forgotten bike loses its files. `store.forBike(deviceId)` returns a `DebugLog` that checks the preference at each call, so a session does not need a rebuild when the rider changes the preference. Every `debugLog` parameter defaults to `NoopDebugLog`. While the app is in the background the store writes each line at once, and on an uncaught error it writes one `app` line (`uncaught error: <type>: <message>`, no stack) to each enabled bike and flushes.
- The Dart files are `<id>.log` and `<id>.1.log`. The native files are `<id>.native.log` and `<id>.native.1.log`. A file rotates at 2 MB. `<id>` is the device id in upper case, with each character outside `A-Z0-9` replaced by `_`. Kotlin (`DebugFileLog.kt`) uses the same rule. It reads the preference from the database (schema v8 or newer) and caches it for 30 seconds. A failed read is not cached. Before it creates a new native file, it reads the preference again, so a forgotten bike gets no file.
- The hold gateway logs its results (permissions, start, stop, text update) to the log of the bike of the active session, and the coordinator logs the hold decisions there.
- Share merges the four files by time into the export file `debug_logs/export/<id>.txt`, with a header (app version, BLE identifier, module serial, live session state). Clear deletes the four files and the export file.
- The settings page reads the size and the time span from the first and last 4 KB of each file, not from the full log. It refreshes them when the store reports a write.
- The log holds the BLE identifier and the module serial of the bike.

## Repository rules

- Version control is jj (colocated with git).
- These files use CRLF line endings: `Makefile`, `analysis_options.yaml`, `pubspec.yaml`, `lib/src/features/add_bike/add_bike_controller.dart`, `lib/src/features/bike_control/bike_control_page.dart`, `lib/src/features/bike_settings/bike_settings_page.dart`, `lib/src/features/hardware_test/bike_hardware_test_controller.dart`, `test/widget/foreground_workflow_test.dart`. `README.md` has mixed line endings. Keep the line endings of each file; new files use LF.
- `docs/superpowers/` holds older local plans and specs. `.git/info/exclude` excludes it from version control.
- `docs/` also holds upstream's design notes and a separate Hugo site (`make docs`).
