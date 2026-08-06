// Entrypoint for driving the app in a dev session (flutter run -t
// test_driver/app.dart). Enables the Flutter Driver extension so external
// tooling can tap/scroll the real app; never used in release builds.
import 'package:flutter_driver/driver_extension.dart';
import 'package:superduper/main.dart' as app;

void main() {
  enableFlutterDriverExtension();
  app.main();
}
