package com.loomilabs.superduperch

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The MethodChannel `io.kbl.superduper/background_sync` of one Flutter engine.
 * It lives as long as the engine, so an activity that goes away does not
 * remove the handler or the `bikeAppeared` sink.
 */
internal class BackgroundSyncChannel(
    private val context: Context,
    engine: FlutterEngine,
) {
    /** The activity that can show the association chooser. Null without one. */
    @Volatile
    var associationHost: MainActivity? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, name)

    init {
        BackgroundSyncRuntime.bikeAppearedSink = { deviceId ->
            mainHandler.post {
                channel.invokeMethod("bikeAppeared", mapOf("deviceId" to deviceId))
            }
        }
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "configure" -> {
                        val deviceId = call.argument<String>("deviceId")
                            ?: throw IllegalArgumentException("deviceId is required")
                        val requestAssociation =
                            call.argument<Boolean>("requestAssociation") ?: false
                        configure(deviceId, requestAssociation, result)
                    }
                    "cancel" -> {
                        associationHost?.cancelPendingAssociation(
                            "Bike association was cancelled",
                        )
                        BackgroundCompanionManager.cancel(context)
                        result.success(null)
                    }
                    "setLinkHeld" -> {
                        val held = call.argument<Boolean>("held")
                            ?: throw IllegalArgumentException("held is required")
                        BackgroundSyncRuntime.dartHoldsLink = held
                        writeHoldWish(held)
                        result.success(null)
                    }
                    "setConnectionPaused" -> {
                        val paused = call.argument<Boolean>("paused")
                            ?: throw IllegalArgumentException("paused is required")
                        BackgroundCompanionManager.setConnectionPaused(context, paused)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("background_sync", error.message, null)
            }
        }
    }

    private fun configure(
        deviceId: String,
        requestAssociation: Boolean,
        result: MethodChannel.Result,
    ) {
        val host = associationHost
        if (requestAssociation && host == null) {
            result.error("background_sync", "Open the app to pair the bike.", null)
            return
        }
        if (host != null) {
            host.configureBackgroundSync(deviceId, requestAssociation, result)
            return
        }
        // Without an activity only a stored association can be configured.
        val address = BackgroundCompanionManager.normalizeDeviceId(deviceId)
        if (!BackgroundCompanionManager.hasCompanionSupport(context)) {
            result.success(false)
            return
        }
        result.success(BackgroundCompanionManager.configureIfAssociated(context, address))
    }

    /** A failed write must not stop the call: `setLinkHeld` always answers. */
    private fun writeHoldWish(held: Boolean) {
        try {
            HoldIntent.file(context).write(held)
        } catch (error: Exception) {
            MainEngine.logNative(context, "hold wish not written: ${error.message}")
        }
    }

    companion object {
        const val name = "io.kbl.superduper/background_sync"
    }
}
