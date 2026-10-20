import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:superduper/src/app.dart';
import 'package:superduper/src/app_services.dart';
import 'package:superduper/src/diagnostics/debug_log.dart';

/// The native side starts the engine without a screen with the argument
/// `headless` when the hold wish is on disk.
void main(List<String> args) {
  final headless = args.contains('headless');
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  installDebugLogErrorFlush(() => SuperduperBootstrap.currentDebugLogStore);

  if (kDebugMode) {
    unawaited(FlutterBluePlus.setLogLevel(LogLevel.verbose, color: false));
  }

  runApp(
    SuperduperBootstrap(
      // A restart of the services in a running app is no headless start.
      createServices: () => AppServices.standard(
        startsHeadless:
            headless &&
            WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed,
      ),
    ),
  );
}
