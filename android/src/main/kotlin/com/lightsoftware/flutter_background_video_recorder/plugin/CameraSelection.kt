package com.lightsoftware.flutter_background_video_recorder.plugin

import kotlin.math.abs
import kotlin.math.hypot

/**
 * Which camera to use: the one with the id [cameraId] when it is set, otherwise the first camera
 * facing the way [frontFacing] says.
 */
internal data class CameraChoice(val cameraId: String?, val frontFacing: Boolean)

/** The values of the `cameraFacing` argument on the method channel. */
internal const val FACING_FRONT = "front"
internal const val FACING_REAR = "rear"

/** Whether [value] is one of the two facings the method channel carries. */
internal fun isValidFacing(value: String?) = value == FACING_FRONT || value == FACING_REAR

/** What to tell the app when [this] choice matches no camera of the device. */
internal fun CameraChoice.notFoundMessage(): String =
    if (cameraId != null) "The chosen camera is not available." else "No ${if (frontFacing) "front" else "rear"} camera available."

/** The zoom ratios a camera supports. 1.0 is its normal view; below zooms out, above zooms in. */
internal data class ZoomRange(val min: Float, val max: Float) {
    /** [ratio] limited to the range. A ratio that is not a number becomes 1.0 (limited as well). */
    fun clamp(ratio: Float): Float {
        val wanted = if (ratio.isNaN()) 1f else ratio
        return wanted.coerceIn(min, max)
    }

    companion object {
        val NONE = ZoomRange(1f, 1f)
    }
}

private const val FULL_FRAME_DIAGONAL_MM = 43.2666f

/**
 * The focal length a lens would have on a 35 mm film camera for the same field of view, which makes
 * lenses on sensors of different sizes comparable. Null when the numbers cannot be used.
 */
internal fun equivalentFocalLength(focalLengthMm: Float, sensorWidthMm: Float, sensorHeightMm: Float): Float? {
    val diagonal = hypot(sensorWidthMm, sensorHeightMm)
    if (focalLengthMm <= 0f || diagonal <= 0f || diagonal.isNaN()) return null
    return focalLengthMm * FULL_FRAME_DIAGONAL_MM / diagonal
}

/**
 * Picks the size of the frames of a frame session out of the sizes the camera can deliver
 * ([choices]). With a [requested] size the closest one is used: first by aspect ratio, then by
 * pixel count. Without one it is the largest size up to 720p, as for a preview.
 * Returns null when [choices] is empty.
 */
internal fun chooseFrameDimension(choices: List<VideoDimension>, requested: VideoDimension?): VideoDimension? {
    if (requested == null) return choosePreviewDimension(choices, null)
    val landscape = choices.filter { it.width >= it.height }.ifEmpty { choices }
    if (landscape.isEmpty()) return null
    val wanted = if (requested.width >= requested.height) requested else VideoDimension(requested.height, requested.width)
    val wantedAspect = wanted.width.toDouble() / wanted.height
    return landscape.minWithOrNull(
        compareBy<VideoDimension> { abs(it.width.toDouble() / it.height - wantedAspect) }
            .thenBy { abs(it.area - wanted.area) },
    )
}
