package com.loomilabs.superduperch

import android.content.Context
import java.io.File

/** The hold wish on disk. The file holds "1" or "0". */
internal class HoldIntentFile(private val file: File) {
    fun write(wanted: Boolean) {
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(if (wanted) "1" else "0")
        if (!temp.renameTo(file)) {
            // Some file systems do not replace a file on rename.
            file.delete()
            if (!temp.renameTo(file)) {
                temp.delete()
                throw java.io.IOException("Could not replace ${file.name}")
            }
        }
    }

    fun read(): Boolean = try {
        file.readText() == "1"
    } catch (_: Exception) {
        false
    }
}

internal object HoldIntent {
    fun file(context: Context): HoldIntentFile =
        HoldIntentFile(File(context.filesDir, "hold_wanted"))

    fun shouldStartHeadless(holdWanted: Boolean, engineRunning: Boolean): Boolean =
        holdWanted && !engineRunning
}
