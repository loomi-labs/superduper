package com.loomilabs.superduperch

import java.io.File
import java.nio.file.Files
import java.time.ZoneOffset
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DebugFileLogTest {
    private lateinit var directory: File
    private var enabled = true
    private var now = 1_791_461_000_000L

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("debug_file_log").toFile()
    }

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    private fun sink(maxBytes: Long = 2L * 1024 * 1024) = DebugFileSink(
        directory = directory,
        isEnabled = { enabled },
        maxBytes = maxBytes,
        clock = { now },
        zone = ZoneOffset.ofHours(2),
    )

    @Test
    fun fileIdUpperCasesAndReplacesOtherCharacters() {
        assertEquals("AA_BB_01", DebugFileSink.fileId("aa:bb-01"))
        assertEquals("AABB", DebugFileSink.fileId("AABB"))
    }

    @Test
    fun lineHasTimeSourceNoGenerationAreaAndMessage() {
        sink().log("aa:bb", "native", "plan loaded")
        val line = File(directory, "AA_BB.native.log").readLines().single()
        assertTrue(line, line.matches(Regex(
            """\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}\+02:00 N --  native  plan loaded""",
        )))
    }

    @Test
    fun disabledLogWritesNoFile() {
        enabled = false
        sink().log("aa:bb", "native", "plan loaded")
        assertEquals(0, directory.listFiles()?.size ?: 0)
    }

    @Test
    fun rotationMovesTheFileToNativeOneAtTheLimit() {
        val sink = sink(maxBytes = 300)
        repeat(12) { sink.log("aa:bb", "native", "line $it padding padding padding") }
        assertTrue(File(directory, "AA_BB.native.1.log").isFile)
        assertTrue(File(directory, "AA_BB.native.log").length() <= 300)
        assertEquals(2, directory.listFiles()!!.size)
    }

    @Test
    fun aFailingWriteNeverThrows() {
        val blocked = File(directory, "blocked").also { it.writeText("x") }
        val sink = DebugFileSink(
            directory = File(blocked, "nested"),
            isEnabled = { true },
            clock = { now },
        )
        sink.log("aa:bb", "native", "x")
        assertFalse(File(blocked, "nested").exists())
    }

    @Test
    fun enabledCacheReadsOnceInTheTtl() {
        var reads = 0
        var time = 0L
        val cache = EnabledCache(ttlMs = 30_000, clock = { time }) { reads++; true }
        assertTrue(cache.get("a"))
        time = 29_000
        assertTrue(cache.get("a"))
        assertEquals(1, reads)
        time = 31_000
        cache.get("a")
        assertEquals(2, reads)
    }

    @Test
    fun aFailedReadIsNotCached() {
        var calls = 0
        val cache = EnabledCache(ttlMs = 30_000, clock = { 0L }) {
            calls++
            if (calls == 1) null else true
        }
        assertFalse(cache.get("a"))
        assertTrue(cache.get("a"))
        assertEquals(2, calls)
    }

    @Test
    fun preferenceNeedsSchemaEightAndARowWithTheFlag() {
        assertFalse(DebugFileLog.decide(7, 1))
        assertFalse(DebugFileLog.decide(8, null))
        assertFalse(DebugFileLog.decide(8, 0))
        assertTrue(DebugFileLog.decide(8, 1))
    }

    @Test
    fun aMessageWithLineBreaksStaysOneLine() {
        sink().log("aa:bb", "native", "a\nb\r\nc")
        val lines = File(directory, "AA_BB.native.log").readLines()
        assertEquals(1, lines.size)
        assertTrue(lines.single().endsWith("a | b | c"))
    }

    @Test
    fun aNewFileNeedsAFreshPreference() {
        var fresh = false
        val sink = DebugFileSink(
            directory = directory,
            isEnabled = { true },
            isEnabledFresh = { fresh },
            clock = { now },
        )
        sink.log("aa:bb", "native", "the bike is gone")
        assertEquals(0, directory.listFiles()?.size ?: 0)

        fresh = true
        sink.log("aa:bb", "native", "the bike is back")
        sink.log("aa:bb", "native", "second")
        assertEquals(2, File(directory, "AA_BB.native.log").readLines().size)
    }
}
