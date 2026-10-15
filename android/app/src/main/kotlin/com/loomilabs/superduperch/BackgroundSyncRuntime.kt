package com.loomilabs.superduperch

internal object BackgroundSyncRuntime {
    @Volatile
    var isActivityForeground = false

    /** Sends "the bike appeared" to Dart. Null while no Flutter engine runs. */
    @Volatile
    var bikeAppearedSink: ((String) -> Unit)? = null

    /** Returns true when a sink took the event. A failing sink never throws. */
    fun notifyBikeAppeared(deviceId: String): Boolean {
        val sink = bikeAppearedSink ?: return false
        return try {
            sink(deviceId)
            true
        } catch (_: RuntimeException) {
            false
        }
    }
}
