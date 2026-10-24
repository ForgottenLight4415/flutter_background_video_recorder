package com.lightsoftware.flutter_background_video_recorder.plugin

import android.content.ContentValues
import android.content.Context
import android.media.MediaRecorder
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private const val DEFAULT_FOLDER = "Recordings"

/**
 * Turns a user supplied folder name into a safe relative path: drops empty and `..` segments and
 * characters that are invalid in file names. Nested folders ("A/B") are kept.
 */
internal fun sanitizeFolderName(raw: String?): String {
    val segments = (raw ?: "")
        .split('/', '\\')
        .map { it.replace(Regex("[:*?\"<>|]"), "").trim() }
        .filter { it.isNotEmpty() && it != "." && it != ".." }
    return segments.joinToString("/").ifEmpty { DEFAULT_FOLDER }
}

/**
 * Destination of one recording: a pending MediaStore entry that becomes visible once [finish] is
 * called. Videos go to `Movies/<folder>`, audio to `Recordings/<folder>`.
 */
internal class MediaOutput private constructor(
    private val context: Context,
    private val contentUri: Uri,
    private val descriptor: ParcelFileDescriptor,
    private val kind: MediaKind,
) {
    fun applyTo(recorder: MediaRecorder) {
        recorder.setOutputFile(descriptor.fileDescriptor)
    }

    /** Publishes the finished video and returns where it ended up. */
    fun finish(): RecordedMedia {
        descriptor.close()
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        context.contentResolver.update(contentUri, values, null, null)
        return RecordedMedia(contentUri.toString(), queryPath(contentUri), kind)
    }

    /** Removes the partial video. Safe to call more than once. */
    fun discard() {
        try {
            descriptor.close()
        } catch (_: IOException) {
        }
        context.contentResolver.delete(contentUri, null, null)
    }

    @Suppress("DEPRECATION")
    private fun queryPath(uri: Uri): String? = try {
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (_: RuntimeException) {
        null
    }

    companion object {
        @Throws(IOException::class)
        fun create(
            context: Context,
            kind: MediaKind,
            folderName: String?,
            nowMillis: Long = System.currentTimeMillis(),
        ): MediaOutput {
            val folder = sanitizeFolderName(folderName)
            val stamp = SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US).format(Date(nowMillis))
            val baseName = "${folder.substringAfterLast('/').replace(" ", "")}_$stamp"

            val (collection, directory, mimeType, extension) = when (kind) {
                MediaKind.VIDEO -> Layout(
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                    Environment.DIRECTORY_MOVIES,
                    "video/mp4",
                    "mp4",
                )
                MediaKind.AUDIO -> Layout(
                    MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                    Environment.DIRECTORY_RECORDINGS,
                    "audio/mp4",
                    "m4a",
                )
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "$baseName.$extension")
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$directory/$folder")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(collection, values) ?: throw IOException("MediaStore insert failed")
            try {
                // MediaRecorder needs a seekable descriptor to write the MP4 header, hence "rw".
                val pfd = resolver.openFileDescriptor(uri, "rw") ?: throw IOException("Could not open $uri")
                return MediaOutput(context, uri, pfd, kind)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw if (e is IOException) e else IOException(e)
            }
        }

        private data class Layout(val collection: Uri, val directory: String, val mimeType: String, val extension: String)
    }
}
