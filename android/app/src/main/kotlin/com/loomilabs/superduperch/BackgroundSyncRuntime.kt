package com.loomilabs.superduperch

internal object BackgroundSyncRuntime {
    @Volatile
    var isActivityForeground = false
}
