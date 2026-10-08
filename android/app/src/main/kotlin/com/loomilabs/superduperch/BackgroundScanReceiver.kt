package com.loomilabs.superduperch

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BackgroundScanReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BackgroundCompanionManager.scanAction) return
        val errorCode = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (errorCode != 0) {
            Log.w(logTag, "Background BLE advertisement scan failed: $errorCode")
            BackgroundCompanionManager.preferences(context)
                .getString(BackgroundCompanionManager.deviceIdKey, null)
                ?.let {
                    DebugFileLog.log(context, it, "native", "advertisement scan failed: code $errorCode")
                }
            BackgroundCompanionManager.recordScanFailure(context, errorCode)
            return
        }
        val callbackType = intent.getIntExtra(
            BluetoothLeScanner.EXTRA_CALLBACK_TYPE,
            ScanSettings.CALLBACK_TYPE_ALL_MATCHES,
        )
        val deviceId = BackgroundCompanionManager.preferences(context)
            .getString(BackgroundCompanionManager.deviceIdKey, null)
            ?: return
        if (callbackType and ScanSettings.CALLBACK_TYPE_MATCH_LOST != 0) {
            Log.d(logTag, "Background BLE advertisement disappeared")
            DebugFileLog.log(context, deviceId, "native", "advertisement scan: bike disappeared")
            return
        }
        if (callbackType and ScanSettings.CALLBACK_TYPE_FIRST_MATCH == 0) return

        Log.d(logTag, "Background BLE advertisement appeared; requesting native sync")
        DebugFileLog.log(context, deviceId, "native", "advertisement scan: bike appeared, request native sync")
        NativeBackgroundSync.synchronize(context, deviceId, "bleScanFirstMatch")
    }

    private companion object {
        const val logTag = "BackgroundSync"
    }
}
