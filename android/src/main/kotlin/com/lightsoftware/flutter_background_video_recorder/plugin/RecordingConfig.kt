package com.lightsoftware.flutter_background_video_recorder.plugin

import android.content.Context
import android.content.Intent

internal enum class RecordingMode(val wire: String) {
    VIDEO("video"),
    AUDIO("audio"),
    ;

    companion object {
        fun fromWire(value: String?): RecordingMode = entries.firstOrNull { it.wire == value } ?: VIDEO
    }
}

/**
 * Everything the service needs to run one recording. Resolved and validated before the service
 * starts. [video] is set for [RecordingMode.VIDEO] and null for audio-only recordings.
 */
internal data class RecordingConfig(
    val mode: RecordingMode,
    val folderName: String,
    val frontFacing: Boolean,
    val video: ResolvedVideo?,
    val notificationTitle: String,
    val notificationText: String,
    /** Position to store in the video's metadata, or null. */
    val location: Coordinates? = null,
    /** Feed the camera picture to the on-screen preview too (see [PreviewRelay]). */
    val preview: Boolean = false,
) {
    fun toIntent(context: Context): Intent {
        val intent = Intent(context, VideoRecorderService::class.java)
            .setAction(VideoRecorderService.ACTION_START)
            .putExtra(EXTRA_MODE, mode.wire)
            .putExtra(EXTRA_FOLDER_NAME, folderName)
            .putExtra(EXTRA_FRONT_FACING, frontFacing)
            .putExtra(EXTRA_NOTIFICATION_TITLE, notificationTitle)
            .putExtra(EXTRA_NOTIFICATION_TEXT, notificationText)
            .putExtra(EXTRA_PREVIEW, preview)
        location?.let { intent.putExtra(EXTRA_LATITUDE, it.latitude).putExtra(EXTRA_LONGITUDE, it.longitude) }
        video?.let {
            intent.putExtra(EXTRA_WIDTH, it.dimension.width)
                .putExtra(EXTRA_HEIGHT, it.dimension.height)
                .putExtra(EXTRA_FRAME_RATE, it.frameRate)
                .putExtra(EXTRA_CODEC, it.codec.wire)
                .putExtra(EXTRA_BITRATE, it.bitrate)
        }
        return intent
    }

    companion object {
        private const val EXTRA_MODE = "mode"
        private const val EXTRA_FOLDER_NAME = "folderName"
        private const val EXTRA_FRONT_FACING = "frontFacing"
        private const val EXTRA_WIDTH = "width"
        private const val EXTRA_HEIGHT = "height"
        private const val EXTRA_FRAME_RATE = "frameRate"
        private const val EXTRA_CODEC = "codec"
        private const val EXTRA_BITRATE = "bitrate"
        private const val EXTRA_PREVIEW = "preview"
        private const val EXTRA_LATITUDE = "latitude"
        private const val EXTRA_LONGITUDE = "longitude"
        private const val EXTRA_NOTIFICATION_TITLE = "notificationTitle"
        private const val EXTRA_NOTIFICATION_TEXT = "notificationText"

        /** Null if the intent does not carry a complete configuration. */
        fun fromIntent(intent: Intent): RecordingConfig? {
            val mode = RecordingMode.fromWire(intent.getStringExtra(EXTRA_MODE))
            val video = if (mode == RecordingMode.VIDEO) {
                val width = intent.getIntExtra(EXTRA_WIDTH, 0)
                val height = intent.getIntExtra(EXTRA_HEIGHT, 0)
                val frameRate = intent.getIntExtra(EXTRA_FRAME_RATE, 0)
                val bitrate = intent.getIntExtra(EXTRA_BITRATE, 0)
                if (width <= 0 || height <= 0 || frameRate <= 0 || bitrate <= 0) return null
                ResolvedVideo(
                    VideoDimension(width, height),
                    frameRate,
                    EncoderCodec.fromWire(intent.getStringExtra(EXTRA_CODEC)),
                    bitrate,
                )
            } else {
                null
            }
            return RecordingConfig(
                mode = mode,
                folderName = intent.getStringExtra(EXTRA_FOLDER_NAME).orEmpty(),
                frontFacing = intent.getBooleanExtra(EXTRA_FRONT_FACING, false),
                video = video,
                notificationTitle = intent.getStringExtra(EXTRA_NOTIFICATION_TITLE).orEmpty(),
                notificationText = intent.getStringExtra(EXTRA_NOTIFICATION_TEXT).orEmpty(),
                preview = intent.getBooleanExtra(EXTRA_PREVIEW, false),
                location = if (intent.hasExtra(EXTRA_LATITUDE) && intent.hasExtra(EXTRA_LONGITUDE)) {
                    Coordinates(intent.getDoubleExtra(EXTRA_LATITUDE, 0.0), intent.getDoubleExtra(EXTRA_LONGITUDE, 0.0))
                } else {
                    null
                },
            )
        }
    }
}
