package com.loomilabs.superduperch

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import io.flutter.util.PathUtils
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * The native part of the debug log of a bike. It appends to
 * `<data dir>/debug_logs/<id>.native.log`. The Dart side writes `<id>.log` in the
 * same folder and merges the files when the rider shares the log.
 */
internal object DebugFileLog {
    private const val databaseFilename = "superduper.sqlite"
    private const val minimumSchemaVersion = 8
    private const val folderName = "debug_logs"
    private const val cacheTtlMs = 30_000L

    @Volatile
    private var sink: DebugFileSink? = null

    fun log(context: Context, deviceId: String, area: String, message: String) {
        try {
            sinkFor(context.applicationContext).log(deviceId, area, message)
        } catch (_: Exception) {
            // A log failure must never break the sync.
        }
    }

    private fun sinkFor(context: Context): DebugFileSink {
        sink?.let { return it }
        synchronized(this) {
            sink?.let { return it }
            val directory = File(PathUtils.getDataDirectory(context), folderName)
            val cache = EnabledCache(cacheTtlMs, System::currentTimeMillis) { deviceId ->
                readPreference(context, deviceId)
            }
            return DebugFileSink(
                directory,
                isEnabled = cache::get,
                isEnabledFresh = cache::getFresh,
            ).also { sink = it }
        }
    }

    /** Null when the database cannot be read now. The cache keeps no value then. */
    private fun readPreference(context: Context, deviceId: String): Boolean? {
        val databaseFile = File(PathUtils.getDataDirectory(context), databaseFilename)
        if (!databaseFile.isFile) return false
        val flags = SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS
        return try {
            SQLiteDatabase.openDatabase(databaseFile.path, null, flags).use { database ->
                val version = database.rawQuery("PRAGMA user_version", null).use { cursor ->
                    if (cursor.moveToFirst()) cursor.getInt(0) else 0
                }
                if (version < minimumSchemaVersion) return@use false
                val row = database.rawQuery(
                    "SELECT debug_log_enabled FROM bike_preferences " +
                        "WHERE device_id = ? COLLATE NOCASE",
                    arrayOf(deviceId),
                ).use { cursor -> if (cursor.moveToFirst()) cursor.getInt(0) else null }
                decide(version, row)
            }
        } catch (_: Exception) {
            // A locked database, for example: ask again at the next line.
            null
        }
    }

    /** The preference from the schema version and the stored value (null: no row). */
    fun decide(userVersion: Int, row: Int?): Boolean =
        userVersion >= minimumSchemaVersion && row != null && row != 0
}

/** Caches the preference of each device for [ttlMs]. */
internal class EnabledCache(
    private val ttlMs: Long,
    private val clock: () -> Long,
    private val load: (String) -> Boolean?,
) {
    private data class Entry(val value: Boolean, val at: Long)

    private val entries = HashMap<String, Entry>()

    /** Reads the preference again and replaces the cache entry. */
    @Synchronized
    fun getFresh(deviceId: String): Boolean = read(deviceId, clock())

    @Synchronized
    fun get(deviceId: String): Boolean {
        val key = DebugFileSink.fileId(deviceId)
        val now = clock()
        entries[key]?.let { if (now - it.at < ttlMs) return it.value }
        return read(deviceId, now)
    }

    private fun read(deviceId: String, now: Long): Boolean {
        val key = DebugFileSink.fileId(deviceId)
        // A failed read (null) is not cached.
        val value = load(deviceId) ?: return false
        entries[key] = Entry(value, now)
        return value
    }
}

/**
 * The files of one bike in the debug log folder: `<id>.log`, `<id>.<k>.log`,
 * `<id>.native.log` and `<id>.native.<k>.log`. A higher k is a newer file.
 */
internal object DebugLogFiles {
    const val maxAgeMs = 30L * 24 * 60 * 60 * 1000
    const val maxBytesPerBike = 300L * 1024 * 1024

    data class Entry(val file: File, val native: Boolean, val rotation: Int)

    fun list(directory: File, id: String): List<Entry> {
        val pattern = Regex("^" + Regex.escape(id) + """(\.native)?(?:\.(\d+))?\.log$""")
        val names = directory.list() ?: return emptyList()
        return names.mapNotNull { name ->
            val match = pattern.matchEntire(name) ?: return@mapNotNull null
            val file = File(directory, name)
            if (!file.isFile) return@mapNotNull null
            Entry(
                file,
                native = match.groupValues[1].isNotEmpty(),
                rotation = match.groupValues[2].toIntOrNull() ?: 0,
            )
        }
    }

    /** The highest rotation number of one kind plus 1 (1 when none exists). */
    fun nextRotation(directory: File, id: String, native: Boolean): Int =
        (list(directory, id).filter { it.native == native }.maxOfOrNull { it.rotation } ?: 0) + 1

    /**
     * Deletes the rotated files older than [maxAgeMs]. Then, while the files of
     * the bike are above [maxBytes], it deletes the rotated file with the oldest
     * modification time. A current file stays. A failed delete is ignored.
     */
    fun prune(
        directory: File,
        id: String,
        now: Long,
        maxAgeMs: Long = DebugLogFiles.maxAgeMs,
        maxBytes: Long = maxBytesPerBike,
    ) {
        try {
            val entries = list(directory, id)
            var total = entries.sumOf { it.file.length() }
            val rotated = entries.filter { it.rotation > 0 }.toMutableList()
            fun remove(entry: Entry) {
                val size = entry.file.length()
                if (entry.file.delete()) {
                    total -= size
                    rotated.remove(entry)
                }
            }
            for (entry in rotated.toList()) {
                if (now - entry.file.lastModified() > maxAgeMs) remove(entry)
            }
            for (entry in rotated.sortedBy { it.file.lastModified() }) {
                if (total <= maxBytes) break
                remove(entry)
            }
        } catch (_: Exception) {
            // A log failure must never break the sync.
        }
    }
}

/** Appends lines to `<id>.native.log` and rotates to `<id>.native.<k>.log`. */
internal class DebugFileSink(
    private val directory: File,
    private val isEnabled: (String) -> Boolean,
    private val isEnabledFresh: (String) -> Boolean = isEnabled,
    private val maxBytes: Long = 2L * 1024 * 1024,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: ZoneId = ZoneId.systemDefault(),
    private val maxAgeMs: Long = DebugLogFiles.maxAgeMs,
    private val maxTotalBytes: Long = DebugLogFiles.maxBytesPerBike,
) {
    private val lock = Any()

    fun log(deviceId: String, area: String, message: String) {
        if (!isEnabled(deviceId)) return
        val id = fileId(deviceId)
        // A new file needs a fresh answer: a forgotten bike must not get a file
        // from a cached \"on\".
        if (!File(directory, "$id.native.log").isFile && !isEnabledFresh(deviceId)) return
        val line = formatLine(area, message.replace(lineBreak, " | ")) + "\n"
        synchronized(lock) {
            try {
                directory.mkdirs()
                val file = File(directory, "$id.native.log")
                if (file.isFile && file.length() + line.length > maxBytes) {
                    val next = DebugLogFiles.nextRotation(directory, id, native = true)
                    if (file.renameTo(File(directory, "$id.native.$next.log"))) {
                        file.appendText(line)
                        DebugLogFiles.prune(directory, id, clock(), maxAgeMs, maxTotalBytes)
                        return@synchronized
                    }
                }
                file.appendText(line)
            } catch (_: Exception) {
                // A log failure must never break the sync.
            }
        }
    }

    private fun formatLine(area: String, message: String): String {
        val time = timeFormat.format(Instant.ofEpochMilli(clock()).atZone(zone))
        return "$time N --  ${area.padEnd(7)} $message"
    }

    companion object {
        private val lineBreak = Regex("\r\n|\r|\n")
        private val timeFormat: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSSxxx")

        /** The same rule as the Dart side: upper case, other characters become `_`. */
        fun fileId(deviceId: String): String =
            deviceId.uppercase().replace(Regex("[^A-Z0-9]"), "_")
    }
}
