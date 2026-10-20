package com.loomilabs.superduperch

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The main Flutter engine. It lives in the application, so the Dart session
 * runs on without an activity. The activity attaches to this engine.
 */
internal object MainEngine {
    const val CACHE_ID = "main"
    private const val headlessArgument = "headless"

    private var channel: BackgroundSyncChannel? = null

    /** Main thread only. */
    fun ensure(context: Context, headless: Boolean = false): FlutterEngine {
        FlutterEngineCache.getInstance().get(CACHE_ID)?.let { return it }
        val applicationContext = context.applicationContext
        val engine = FlutterEngine(applicationContext)
        channel = BackgroundSyncChannel(applicationContext, engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
            if (headless) listOf(headlessArgument) else null,
        )
        FlutterEngineCache.getInstance().put(CACHE_ID, engine)
        return engine
    }

    fun isRunning(): Boolean = FlutterEngineCache.getInstance().contains(CACHE_ID)

    /** The channel of the running engine, for the activity. */
    fun channel(): BackgroundSyncChannel? = channel

    /** Main thread only. */
    fun startIfHoldWanted(context: Context) {
        val wanted = HoldIntent.file(context).read()
        if (!HoldIntent.shouldStartHeadless(wanted, isRunning())) return
        logNative(context, "headless start: hold wanted")
        ensure(context, headless = true)
    }

    /** Writes a `native` line to the log of each bike whose log is on. */
    fun logNative(context: Context, message: String) {
        DebugFileLog.logToEnabledBikes(context, "native", message)
    }
}
