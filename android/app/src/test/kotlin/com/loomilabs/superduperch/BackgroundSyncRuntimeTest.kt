package com.loomilabs.superduperch

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundSyncRuntimeTest {
    @After
    fun tearDown() {
        BackgroundSyncRuntime.bikeAppearedSink = null
        BackgroundSyncRuntime.dartHoldsLink = false
    }

    @Test
    fun nativeSyncSkipsWhileDartHoldsTheLink() {
        assertEquals(
            "skippedDartHoldsLink",
            BackgroundSyncRuntime.standDownOutcome(foreground = false, dartHoldsLink = true),
        )
    }

    @Test
    fun nativeSyncRunsWhenDartDoesNotHoldTheLink() {
        assertNull(BackgroundSyncRuntime.standDownOutcome(foreground = false, dartHoldsLink = false))
    }

    @Test
    fun nativeSyncSkipsInTheForeground() {
        assertEquals(
            "skippedForeground",
            BackgroundSyncRuntime.standDownOutcome(foreground = true, dartHoldsLink = true),
        )
    }

    @Test
    fun theLinkHeldFlagIsFalseAtStart() {
        assertFalse(BackgroundSyncRuntime.dartHoldsLink)
    }

    @Test
    fun appearedEventCallsTheSinkWhenOneIsSet() {
        val received = mutableListOf<String>()
        BackgroundSyncRuntime.bikeAppearedSink = { received.add(it) }

        assertTrue(BackgroundSyncRuntime.notifyBikeAppeared("AA:BB:CC:DD:EE:FF"))

        assertEquals(listOf("AA:BB:CC:DD:EE:FF"), received)
    }

    @Test
    fun appearedEventDoesNotFailWhenNoSinkIsSet() {
        BackgroundSyncRuntime.bikeAppearedSink = null

        assertFalse(BackgroundSyncRuntime.notifyBikeAppeared("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun appearedEventDoesNotFailWhenTheSinkFails() {
        BackgroundSyncRuntime.bikeAppearedSink = { throw IllegalStateException("engine gone") }

        assertFalse(BackgroundSyncRuntime.notifyBikeAppeared("AA:BB:CC:DD:EE:FF"))
    }
}
