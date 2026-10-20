package com.loomilabs.superduperch

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HoldIntentTest {
    private lateinit var directory: File

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("hold_intent").toFile()
    }

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    private fun intent() = HoldIntentFile(File(directory, "hold_wanted"))

    @Test
    fun missingFileReadsFalse() {
        assertFalse(intent().read())
    }

    @Test
    fun writeTrueThenReadTrue() {
        val intent = intent()
        intent.write(true)
        assertTrue(intent.read())
    }

    @Test
    fun writeFalseAfterTrueReadsFalse() {
        val intent = intent()
        intent.write(true)
        intent.write(false)
        assertFalse(intent.read())
    }

    @Test
    fun writeLeavesNoTempFile() {
        intent().write(true)
        assertEquals(listOf("hold_wanted"), directory.list()!!.toList())
    }

    @Test
    fun damagedFileReadsFalse() {
        File(directory, "hold_wanted").writeText("x")
        assertFalse(intent().read())
    }

    @Test
    fun emptyFileReadsFalse() {
        File(directory, "hold_wanted").writeText("")
        assertFalse(intent().read())
    }

    @Test
    fun headlessStartOnlyWhenWantedAndNoEngine() {
        assertTrue(HoldIntent.shouldStartHeadless(true, false))
        assertFalse(HoldIntent.shouldStartHeadless(true, true))
        assertFalse(HoldIntent.shouldStartHeadless(false, false))
        assertFalse(HoldIntent.shouldStartHeadless(false, true))
    }
}
