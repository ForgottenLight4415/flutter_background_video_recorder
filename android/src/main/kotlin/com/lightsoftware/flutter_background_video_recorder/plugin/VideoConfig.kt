package com.lightsoftware.flutter_background_video_recorder.plugin

/*
 * Pure logic for deciding how to record: which resolution, frame rate, codec and bitrate. It works
 * on plain data classes (no Android types) so that it can be unit tested on the JVM. The Android
 * side that fills these in is CameraCapabilities.kt.
 */

/** What the app asks for. A null field means "use the default". */
internal enum class VideoCodec(val wire: String) {
    H264("h264"),
    HEVC("hevc"),

    /** HEVC when the device has a hardware HEVC encoder, otherwise H.264. */
    AUTO("auto"),
    ;

    companion object {
        fun fromWire(value: String?): VideoCodec = entries.firstOrNull { it.wire == value } ?: H264
    }
}

/** The codec that is actually used. */
internal enum class EncoderCodec(val wire: String, val mime: String) {
    H264("h264", "video/avc"),
    HEVC("hevc", "video/hevc"),
    ;

    companion object {
        fun fromWire(value: String?): EncoderCodec = entries.firstOrNull { it.wire == value } ?: H264
    }
}

internal data class FpsRange(val lower: Int, val upper: Int)

/** A resolution the camera can record, with the frame rates it can record it at. */
internal data class VideoMode(val dimension: VideoDimension, val frameRates: List<Int>)

internal data class CodecSupport(val supported: Boolean, val hardware: Boolean)

internal data class CodecAvailability(val h264: CodecSupport, val hevc: CodecSupport)

internal data class VideoRequest(
    val width: Int? = null,
    val height: Int? = null,
    val frameRate: Int? = null,
    val codec: VideoCodec = VideoCodec.H264,
    val bitrate: Int? = null,
)

internal data class ResolvedVideo(
    val dimension: VideoDimension,
    val frameRate: Int,
    val codec: EncoderCodec,
    val bitrate: Int,
)

/** A bitrate the device manufacturer recommends for some size and frame rate. */
internal data class ReferenceBitrate(val bitrate: Int, val dimension: VideoDimension, val frameRate: Int)

/** The request asks for something this device cannot record. */
internal class UnsupportedConfigurationException(message: String) : Exception(message)

private val CANDIDATE_FRAME_RATES = listOf(24, 25, 30, 48, 50, 60)
private val FULL_HD = VideoDimension(1920, 1080)
private const val MIN_BITRATE = 1_000_000L
private const val MAX_BITRATE = 100_000_000L

/**
 * Frame rates (24 to 60) that can be recorded at one size. A frame rate needs an auto-exposure
 * range that ends at it (so the camera really delivers it), and both the sensor and the encoder
 * must be fast enough.
 */
internal fun supportedFrameRates(sensorMaxFps: Int, codecMaxFps: Int, aeRanges: List<FpsRange>): List<Int> {
    val limit = minOf(sensorMaxFps, codecMaxFps)
    // Some cameras do not list ranges at all; then only plain 30 fps is safe to promise.
    if (aeRanges.isEmpty()) return listOf(30).filter { it <= limit }
    return CANDIDATE_FRAME_RATES.filter { fps -> fps <= limit && aeRanges.any { it.upper == fps } }
}

/** Every landscape size that can be recorded at at least one frame rate, largest first. */
internal fun buildModes(
    sizes: List<VideoDimension>,
    sensorMaxFps: (VideoDimension) -> Int,
    codecMaxFps: (VideoDimension) -> Int,
    aeRanges: List<FpsRange>,
): List<VideoMode> = sizes
    .filter { it.width >= it.height }
    .distinct()
    .mapNotNull { size ->
        val rates = supportedFrameRates(sensorMaxFps(size), codecMaxFps(size), aeRanges)
        if (rates.isEmpty()) null else VideoMode(size, rates)
    }
    .sortedByDescending { it.dimension.area }

/** The auto-exposure range to request for [fps]: one ending at it, the narrowest (steadiest) first. */
internal fun chooseAeRange(ranges: List<FpsRange>, fps: Int): FpsRange? =
    ranges.filter { it.upper == fps }.maxByOrNull { it.lower }

/**
 * Bitrate for a recording when the device gives no recommendation: bits per pixel per frame,
 * lower for HEVC because it needs fewer bits for the same quality.
 */
internal fun formulaBitrate(dimension: VideoDimension, frameRate: Int, codec: EncoderCodec): Int {
    val bitsPerPixel = if (codec == EncoderCodec.HEVC) 0.15 else 0.25
    return (dimension.area * frameRate * bitsPerPixel).toLong().coerceIn(MIN_BITRATE, MAX_BITRATE).toInt()
}

/** Scales a manufacturer recommendation to another size or frame rate. */
internal fun scaleReferenceBitrate(reference: ReferenceBitrate, dimension: VideoDimension, frameRate: Int): Int {
    val referencePixelsPerSecond = reference.dimension.area.toDouble() * reference.frameRate
    val scale = dimension.area.toDouble() * frameRate / referencePixelsPerSecond
    return (reference.bitrate * scale).toLong().coerceIn(MIN_BITRATE, MAX_BITRATE).toInt()
}

private fun preferredFrameRate(rates: List<Int>): Int = if (60 in rates) 60 else if (30 in rates) 30 else rates.max()

/** 1080p if offered, otherwise the best size up to 1080p. */
private fun defaultMode(modes: List<VideoMode>, requiredFps: Int?): VideoMode? {
    val pool = if (requiredFps == null) modes else modes.filter { requiredFps in it.frameRates }
    pool.firstOrNull { it.dimension == FULL_HD }?.let { return it }
    val best = chooseVideoDimension(pool.map { it.dimension }) ?: return null
    return pool.first { it.dimension == best }
}

/**
 * Turns a request into a concrete recording setup.
 *
 * With nothing specified this is 1080p at 60 fps, else 1080p at 30 fps, else the best size up to
 * 1080p. Anything the app specifies explicitly must be supported, otherwise
 * [UnsupportedConfigurationException] is thrown: a recording is never silently different from
 * what was asked for.
 */
internal fun chooseVideoConfig(
    request: VideoRequest,
    modes: List<VideoMode>,
    codecs: CodecAvailability,
    referenceBitrate: (EncoderCodec) -> ReferenceBitrate? = { null },
    codecMaxFps: (EncoderCodec, VideoDimension) -> Int = { _, _ -> Int.MAX_VALUE },
): ResolvedVideo {
    if (modes.isEmpty()) throw UnsupportedConfigurationException("This camera cannot record video.")

    val mode = when {
        request.width != null && request.height != null -> {
            // Videos are stored landscape and rotated on playback, so portrait sizes are accepted too.
            val wanted = VideoDimension(maxOf(request.width, request.height), minOf(request.width, request.height))
            modes.firstOrNull { it.dimension == wanted }
                ?: throw UnsupportedConfigurationException("${wanted.width}x${wanted.height} is not supported by this camera.")
        }
        request.width != null || request.height != null ->
            throw UnsupportedConfigurationException("Give both width and height, or neither.")
        else -> defaultMode(modes, request.frameRate)
            ?: throw UnsupportedConfigurationException("No resolution supports ${request.frameRate} fps on this camera.")
    }

    val frameRate = request.frameRate
        ?.also {
            if (it !in mode.frameRates) {
                throw UnsupportedConfigurationException(
                    "${mode.dimension.width}x${mode.dimension.height} cannot be recorded at $it fps " +
                        "(supported: ${mode.frameRates.joinToString()}).",
                )
            }
        }
        ?: preferredFrameRate(mode.frameRates)

    val codec = when (request.codec) {
        VideoCodec.H264 -> {
            if (!codecs.h264.supported) throw UnsupportedConfigurationException("This device cannot encode H.264.")
            EncoderCodec.H264
        }
        VideoCodec.HEVC -> {
            if (!codecs.hevc.supported) throw UnsupportedConfigurationException("This device cannot encode HEVC.")
            EncoderCodec.HEVC
        }
        VideoCodec.AUTO ->
            if (codecs.hevc.supported && codecs.hevc.hardware) EncoderCodec.HEVC else EncoderCodec.H264
    }

    // The mode list is built with H.264 limits; another codec may be slower at this size.
    if (frameRate > codecMaxFps(codec, mode.dimension)) {
        throw UnsupportedConfigurationException(
            "${codec.wire.uppercase()} cannot be recorded at ${mode.dimension.width}x${mode.dimension.height} " +
                "and $frameRate fps on this device.",
        )
    }

    val bitrate = when {
        request.bitrate != null -> {
            if (request.bitrate <= 0) throw UnsupportedConfigurationException("The bitrate must be positive.")
            request.bitrate
        }
        else -> referenceBitrate(codec)?.let { scaleReferenceBitrate(it, mode.dimension, frameRate) }
            ?: formulaBitrate(mode.dimension, frameRate, codec)
    }
    return ResolvedVideo(mode.dimension, frameRate, codec, bitrate)
}
