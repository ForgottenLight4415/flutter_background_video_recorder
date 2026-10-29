package com.lightsoftware.flutter_background_video_recorder.plugin

import android.content.Context
import android.content.Intent

/** Everything [FrameCaptureService] needs, resolved and validated before the service starts. */
internal data class FrameSessionConfig(
    val camera: CameraChoice,
    /** The size of the frames before rotation, chosen from what the camera delivers. */
    val dimension: VideoDimension,
    val frame: RawFrameConfig,
    val notificationTitle: String,
    val notificationText: String,
) {
    fun toIntent(context: Context): Intent = Intent(context, FrameCaptureService::class.java)
        .setAction(FrameCaptureService.ACTION_START)
        .putExtra(EXTRA_CAMERA_ID, camera.cameraId)
        .putExtra(EXTRA_FRONT_FACING, camera.frontFacing)
        .putExtra(EXTRA_WIDTH, dimension.width)
        .putExtra(EXTRA_HEIGHT, dimension.height)
        .putExtra(EXTRA_FORMAT, frame.format.wire)
        .putExtra(EXTRA_MAX_FPS, frame.maxFps ?: 0)
        .putExtra(EXTRA_JPEG_QUALITY, frame.jpegQuality)
        .putExtra(EXTRA_ZOOM, frame.initialZoom)
        .putExtra(EXTRA_TITLE, notificationTitle)
        .putExtra(EXTRA_TEXT, notificationText)

    companion object {
        private const val EXTRA_CAMERA_ID = "cameraId"
        private const val EXTRA_FRONT_FACING = "frontFacing"
        private const val EXTRA_WIDTH = "width"
        private const val EXTRA_HEIGHT = "height"
        private const val EXTRA_FORMAT = "format"
        private const val EXTRA_MAX_FPS = "maxFps"
        private const val EXTRA_JPEG_QUALITY = "jpegQuality"
        private const val EXTRA_ZOOM = "zoom"
        private const val EXTRA_TITLE = "notificationTitle"
        private const val EXTRA_TEXT = "notificationText"

        /** Null if the intent does not carry a complete configuration. */
        fun fromIntent(intent: Intent): FrameSessionConfig? {
            val width = intent.getIntExtra(EXTRA_WIDTH, 0)
            val height = intent.getIntExtra(EXTRA_HEIGHT, 0)
            if (width <= 0 || height <= 0) return null
            return FrameSessionConfig(
                camera = CameraChoice(intent.getStringExtra(EXTRA_CAMERA_ID), intent.getBooleanExtra(EXTRA_FRONT_FACING, false)),
                dimension = VideoDimension(width, height),
                frame = RawFrameConfig(
                    format = RawFrameFormat.fromWire(intent.getStringExtra(EXTRA_FORMAT)),
                    maxFps = intent.getIntExtra(EXTRA_MAX_FPS, 0).takeIf { it > 0 },
                    jpegQuality = intent.getIntExtra(EXTRA_JPEG_QUALITY, RawFrameConfig.DEFAULT_JPEG_QUALITY),
                    initialZoom = intent.getFloatExtra(EXTRA_ZOOM, 1f),
                ),
                notificationTitle = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                notificationText = intent.getStringExtra(EXTRA_TEXT).orEmpty(),
            )
        }
    }
}

/** Everything [AudioCaptureService] needs. */
internal data class AudioSessionConfig(
    val audio: RawAudioConfig,
    val notificationTitle: String,
    val notificationText: String,
) {
    fun toIntent(context: Context): Intent = Intent(context, AudioCaptureService::class.java)
        .setAction(AudioCaptureService.ACTION_START)
        .putExtra(EXTRA_SAMPLE_RATE, audio.sampleRate)
        .putExtra(EXTRA_CHANNELS, audio.channels)
        .putExtra(EXTRA_ENCODING, audio.encoding.wire)
        .putExtra(EXTRA_SOURCE, audio.source.wire)
        .putExtra(EXTRA_CHUNK_MS, audio.chunkMs)
        .putExtra(EXTRA_TITLE, notificationTitle)
        .putExtra(EXTRA_TEXT, notificationText)

    companion object {
        private const val EXTRA_SAMPLE_RATE = "sampleRate"
        private const val EXTRA_CHANNELS = "channels"
        private const val EXTRA_ENCODING = "encoding"
        private const val EXTRA_SOURCE = "source"
        private const val EXTRA_CHUNK_MS = "chunkMs"
        private const val EXTRA_TITLE = "notificationTitle"
        private const val EXTRA_TEXT = "notificationText"

        fun fromIntent(intent: Intent): AudioSessionConfig {
            val defaults = RawAudioConfig()
            return AudioSessionConfig(
                audio = RawAudioConfig(
                    sampleRate = intent.getIntExtra(EXTRA_SAMPLE_RATE, defaults.sampleRate),
                    channels = intent.getIntExtra(EXTRA_CHANNELS, defaults.channels),
                    encoding = AudioEncoding.fromWire(intent.getStringExtra(EXTRA_ENCODING)),
                    source = AudioSourceKind.fromWire(intent.getStringExtra(EXTRA_SOURCE)),
                    chunkMs = intent.getIntExtra(EXTRA_CHUNK_MS, defaults.chunkMs),
                ),
                notificationTitle = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                notificationText = intent.getStringExtra(EXTRA_TEXT).orEmpty(),
            )
        }
    }
}
