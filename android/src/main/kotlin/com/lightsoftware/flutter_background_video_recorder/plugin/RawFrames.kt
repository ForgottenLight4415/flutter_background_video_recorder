package com.lightsoftware.flutter_background_video_recorder.plugin

/** How the pixels of a frame sent to the app are laid out. */
internal enum class RawFrameFormat(val wire: String) {
    YUV420("yuv420"),
    JPEG("jpeg"),
    RGBA("rgba"),
    ;

    companion object {
        fun fromWire(value: String?): RawFrameFormat = entries.firstOrNull { it.wire == value } ?: YUV420
    }
}

/** Where one plane of a frame lies in its slot, and how its samples are spaced. */
internal class PlaneLayout(val offset: Int, val length: Int, val rowStride: Int, val pixelStride: Int)

/**
 * One frame on its way to the app. The pixels are in the native slot of [lease], not in this object:
 * valid while a reference on the lease is held. [rotation] is the clockwise turn that makes the
 * picture upright, [dropped] the number of frames the session has dropped so far.
 */
internal class RawFrameData(
    val format: RawFrameFormat,
    val width: Int,
    val height: Int,
    val rotation: Int,
    val timestampNs: Long,
    val lease: FrameLease,
    val planes: List<PlaneLayout>,
    val dropped: Long,
)

/** What the app is told when a frame session has opened. */
internal data class FrameSessionInfo(
    val cameraId: String,
    val width: Int,
    val height: Int,
    val format: RawFrameFormat,
)

/** How the app wants its frames. */
internal data class RawFrameConfig(
    val format: RawFrameFormat = RawFrameFormat.YUV420,
    /** The wanted size before rotation, or null for the default. */
    val size: VideoDimension? = null,
    val maxFps: Int? = null,
    val jpegQuality: Int = DEFAULT_JPEG_QUALITY,
    val initialZoom: Float = 1f,
) {
    companion object {
        const val DEFAULT_JPEG_QUALITY = 80

        /** Reads the arguments of the `openFrameSession` call. Values out of range are limited. */
        fun fromArguments(args: Map<String, Any?>): RawFrameConfig {
            fun number(key: String) = (args[key] as? Number)
            val width = number("width")?.toInt()
            val height = number("height")?.toInt()
            return RawFrameConfig(
                format = RawFrameFormat.fromWire(args["format"] as? String),
                size = if (width != null && height != null && width > 0 && height > 0) VideoDimension(width, height) else null,
                maxFps = number("maxFrameRate")?.toInt()?.takeIf { it > 0 },
                jpegQuality = (number("jpegQuality")?.toInt() ?: DEFAULT_JPEG_QUALITY).coerceIn(1, 100),
                initialZoom = number("initialZoom")?.toFloat() ?: 1f,
            )
        }
    }
}
