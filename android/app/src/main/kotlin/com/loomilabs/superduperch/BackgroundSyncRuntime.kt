package com.loomilabs.superduperch

internal object BackgroundSyncRuntime {
    @Volatile
    var isActivityForeground = false

    /** True while Dart holds the link to the bike: the native sync stands down. */
    @Volatile
    var dartHoldsLink = false

    /** The skip outcome while the app or Dart holds the link, else null. */
    fun standDownOutcome(
        foreground: Boolean = isActivityForeground,
        dartHoldsLink: Boolean = this.dartHoldsLink,
    ): String? = when {
        foreground -> "skippedForeground"
        dartHoldsLink -> "skippedDartHoldsLink"
        else -> null
    }

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
