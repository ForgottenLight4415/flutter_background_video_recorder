package com.lightsoftware.flutter_background_video_recorder.plugin

internal data class VideoDimension(val width: Int, val height: Int) {
    val area: Long get() = width.toLong() * height
}

private const val MAX_WIDTH = 1920
private const val MAX_HEIGHT = 1080

/**
 * Picks the recording resolution: the largest 16:9 size up to 1080p, otherwise the largest size up
 * to 1080p, otherwise (every size is bigger) the smallest one. Returns null when [choices] is empty.
 */
internal fun chooseVideoDimension(choices: List<VideoDimension>): VideoDimension? {
    if (choices.isEmpty()) return null
    val landscape = choices.filter { it.width >= it.height }.ifEmpty { choices }
    val fitting = landscape.filter { it.width <= MAX_WIDTH && it.height <= MAX_HEIGHT }
    if (fitting.isEmpty()) return landscape.minByOrNull { it.area }
    return fitting.filter { it.width * 9 == it.height * 16 }.maxByOrNull { it.area }
        ?: fitting.maxByOrNull { it.area }
}

/**
 * Clockwise rotation that turns the camera's picture upright for the way the device is held.
 * [displayRotationDegrees] is the display rotation (0, 90, 180, 270) as reported by
 * [android.view.Display.getRotation], which is how far the device was turned counterclockwise from
 * its natural orientation. Turning the device counterclockwise turns what a back camera sees
 * clockwise, so the back camera subtracts the rotation; a front camera faces the other way and adds
 * it. (This is the same rule CameraX uses for the relative rotation of the image.)
 */
internal fun videoOrientationHint(
    sensorOrientation: Int,
    displayRotationDegrees: Int,
    frontFacing: Boolean,
): Int {
    val sign = if (frontFacing) 1 else -1
    return (sensorOrientation + sign * displayRotationDegrees + 360) % 360
}

private const val MAX_PREVIEW_WIDTH = 1280
private const val MAX_PREVIEW_HEIGHT = 720
private const val ASPECT_TOLERANCE = 0.02

/**
 * Size of the camera feed used for the on-screen preview. It matches the aspect ratio of the video
 * being recorded (so the preview shows what the video will contain) and stays at or below 720p
 * because a preview needs far fewer pixels than a recording. Without a [wantedAspect] the largest
 * 16:9-ish size is used. Returns null when [choices] is empty.
 */
internal fun choosePreviewDimension(choices: List<VideoDimension>, wantedAspect: Double?): VideoDimension? {
    val landscape = choices.filter { it.width >= it.height }.ifEmpty { choices }
    if (landscape.isEmpty()) return null
    val fitting = landscape.filter { it.width <= MAX_PREVIEW_WIDTH && it.height <= MAX_PREVIEW_HEIGHT }
        .ifEmpty { return landscape.minByOrNull { it.area } }
    val target = wantedAspect ?: (16.0 / 9.0)
    val matching = fitting.filter { Math.abs(it.width.toDouble() / it.height - target) / target < ASPECT_TOLERANCE }
    if (matching.isNotEmpty()) return matching.maxByOrNull { it.area }
    // No size has that aspect ratio: take the closest one.
    return fitting.minWithOrNull(
        compareBy<VideoDimension> { Math.abs(it.width.toDouble() / it.height - target) }.thenByDescending { it.area },
    )
}

/** The size of the preview picture once rotated upright: width and height swap for quarter turns. */
internal fun uprightPreviewSize(buffer: VideoDimension, rotationDegrees: Int): VideoDimension =
    if (rotationDegrees % 180 == 0) buffer else VideoDimension(buffer.height, buffer.width)
