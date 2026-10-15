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
        assertTrue(File(directory, "AA_BB.native.2.log").isFile)
        assertTrue(File(directory, "AA_BB.native.log").length() <= 300)
        // Each rotation keeps the old file: the files number upward.
        assertTrue(directory.listFiles()!!.size > 2)
    }

    @Test
    fun anOldNativeOneStaysAndTheNextRotationMakesTwo() {
        File(directory, "AA_BB.native.1.log").writeText("old\n")
        File(directory, "AA_BB.native.log").writeText("x".repeat(250) + "\n")
        sink(maxBytes = 300).log("aa:bb", "native", "y".repeat(100))
        assertEquals("old\n", File(directory, "AA_BB.native.1.log").readText())
        assertTrue(File(directory, "AA_BB.native.2.log").readText().startsWith("xxx"))
    }

    private fun make(name: String, bytes: Int, ageMs: Long): File =
        File(directory, name).also {
            it.writeText("x".repeat(bytes))
            it.setLastModified(now - ageMs)
        }

    private val day = 24L * 60 * 60 * 1000

    @Test
    fun pruneDeletesRotatedFilesOlderThanThirtyDays() {
        make("AA.1.log", 10, 31 * day)
        make("AA.native.1.log", 10, 31 * day)
        make("AA.2.log", 10, 29 * day)
        make("AA.log", 10, 60 * day)
        DebugLogFiles.prune(directory, "AA", now)
        assertFalse(File(directory, "AA.1.log").exists())
        assertFalse(File(directory, "AA.native.1.log").exists())
        assertTrue(File(directory, "AA.2.log").exists())
        assertTrue(File(directory, "AA.log").exists())
    }

    @Test
    fun pruneDeletesTheOldestRotatedFileFirstAboveTheLimit() {
        make("AA.log", 100, day)
        make("AA.3.log", 100, 2 * day)
        make("AA.native.1.log", 100, 5 * day)
        make("AA.1.log", 100, 9 * day)
        make("AA.2.log", 100, 7 * day)
        make("BB.1.log", 100, 20 * day)
        DebugLogFiles.prune(directory, "AA", now, maxBytes = 250)
        assertFalse(File(directory, "AA.1.log").exists())
        assertFalse(File(directory, "AA.2.log").exists())
        assertFalse(File(directory, "AA.native.1.log").exists())
        assertTrue(File(directory, "AA.3.log").exists())
        assertTrue(File(directory, "AA.log").exists())
        assertTrue(File(directory, "BB.1.log").exists())
    }

    @Test
    fun pruneNeverDeletesACurrentFile() {
        make("AA.log", 300, day)
        make("AA.native.log", 300, day)
        DebugLogFiles.prune(directory, "AA", now, maxBytes = 100)
        assertTrue(File(directory, "AA.log").exists())
        assertTrue(File(directory, "AA.native.log").exists())
    }

    @Test
    fun aNativeRotationPrunesTheFilesOfTheBike() {
        make("AA_BB.1.log", 10, 40 * day)
        File(directory, "AA_BB.native.log").writeText("x".repeat(250) + "\n")
        sink(maxBytes = 300).log("aa:bb", "native", "y".repeat(100))
        assertFalse(File(directory, "AA_BB.1.log").exists())
        assertTrue(File(directory, "AA_BB.native.1.log").exists())
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
