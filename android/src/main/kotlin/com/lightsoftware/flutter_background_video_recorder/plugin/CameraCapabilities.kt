package com.lightsoftware.flutter_background_video_recorder.plugin

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.CamcorderProfile
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaRecorder
import android.util.Size
import kotlin.math.roundToInt

/** What one camera of this device can record. */
internal class CameraCapabilities(
    val cameraId: String,
    val sensorOrientation: Int,
    val stabilization: Boolean,
    val aeRanges: List<FpsRange>,
    val modes: List<VideoMode>,
    val codecs: CodecAvailability,
    /** Sizes the camera can deliver to an on-screen preview. */
    val previewSizes: List<VideoDimension>,
    /** Sizes the camera can deliver as YUV frames (for a frame session). */
    val frameSizes: List<VideoDimension>,
    /** True for a front-facing camera. Decides the rotation and mirroring of its picture. */
    val frontFacing: Boolean,
    val zoomRange: ZoomRange,
)

/** One camera of the device, for the app's camera picker. */
internal class CameraListing(
    val id: String,
    /** `front`, `rear` or `external`. */
    val position: String,
    val sensorOrientation: Int,
    val focalLengthMm: Float?,
    val focalLengthEquivalentMm: Float?,
    val minimumFocusDistance: Float?,
    val zoomRange: ZoomRange,
    val isLogicalMultiCamera: Boolean,
    val physicalCameraIds: List<String>,
)

/** The display's rotation as 0, 90, 180 or 270 degrees. */
internal fun displayRotationDegrees(context: Context): Int {
    val display = context.getSystemService(android.hardware.display.DisplayManager::class.java)
        .getDisplay(android.view.Display.DEFAULT_DISPLAY)
    return when (display?.rotation) {
        android.view.Surface.ROTATION_90 -> 90
        android.view.Surface.ROTATION_180 -> 180
        android.view.Surface.ROTATION_270 -> 270
        else -> 0
    }
}

/** Reads the camera and codec facts that [chooseVideoConfig] decides on. */
internal object CameraCapabilitiesProvider {
    /** Capabilities of the chosen camera, or null if the device has no such camera. */
    fun query(context: Context, choice: CameraChoice): CameraCapabilities? {
        val manager = context.getSystemService(CameraManager::class.java)
        val ids = manager.cameraIdList
        if (choice.cameraId != null) {
            val id = ids.firstOrNull { it == choice.cameraId } ?: return null
            return describe(manager, id)
        }
        val wantedLens = if (choice.frontFacing) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        for (id in ids) {
            val characteristics = manager.getCameraCharacteristics(id)
            if (characteristics.get(CameraCharacteristics.LENS_FACING) != wantedLens) continue
            describe(manager, id)?.let { return it }
        }
        return null
    }

    /** The cameras an app can pick from. Depth-only and similar cameras that cannot make a picture are left out. */
    fun listCameras(context: Context): List<CameraListing> {
        val manager = context.getSystemService(CameraManager::class.java)
        return manager.cameraIdList.mapNotNull { id ->
            try {
                val c = manager.getCameraCharacteristics(id)
                val capabilities = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                if (capabilities != null &&
                    !capabilities.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE)
                ) {
                    return@mapNotNull null
                }
                if (c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) == null) return@mapNotNull null
                val focalLength = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull()
                val sensor = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                CameraListing(
                    id = id,
                    position = when (c.get(CameraCharacteristics.LENS_FACING)) {
                        CameraCharacteristics.LENS_FACING_FRONT -> "front"
                        CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                        else -> "rear"
                    },
                    sensorOrientation = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0,
                    focalLengthMm = focalLength,
                    focalLengthEquivalentMm = if (focalLength != null && sensor != null) {
                        equivalentFocalLength(focalLength, sensor.width, sensor.height)
                    } else {
                        null
                    },
                    minimumFocusDistance = c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE),
                    zoomRange = zoomRangeOf(c),
                    isLogicalMultiCamera = capabilities?.contains(
                        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA,
                    ) == true,
                    physicalCameraIds = c.physicalCameraIds.sorted(),
                )
            } catch (_: CameraAccessException) {
                null
            }
        }
    }

    private fun zoomRangeOf(characteristics: CameraCharacteristics): ZoomRange {
        val range = characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) ?: return ZoomRange.NONE
        return ZoomRange(range.lower, range.upper)
    }

    private fun describe(manager: CameraManager, id: String): CameraCapabilities? {
        val characteristics = manager.getCameraCharacteristics(id)
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return null
        val sizes = map.getOutputSizes(MediaRecorder::class.java)
            ?.map { VideoDimension(it.width, it.height) }
            .orEmpty()
        val aeRanges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.map { FpsRange(it.lower, it.upper) }
            .orEmpty()
        val modes = buildModes(
            sizes = sizes,
            sensorMaxFps = { size ->
                val duration = map.getOutputMinFrameDuration(MediaRecorder::class.java, Size(size.width, size.height))
                if (duration <= 0L) 30 else (1_000_000_000.0 / duration).roundToInt()
            },
            // H.264 is the baseline every device has; HEVC is checked again once it is chosen.
            codecMaxFps = { size -> maxEncoderFps(EncoderCodec.H264, size) },
            aeRanges = aeRanges,
        )
        return CameraCapabilities(
            cameraId = id,
            sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0,
            stabilization = characteristics
                .get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
                ?.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON) == true,
            aeRanges = aeRanges,
            modes = modes,
            codecs = codecAvailability(),
            previewSizes = map.getOutputSizes(android.graphics.SurfaceTexture::class.java)
                ?.map { VideoDimension(it.width, it.height) }
                .orEmpty(),
            frameSizes = map.getOutputSizes(ImageFormat.YUV_420_888)
                ?.map { VideoDimension(it.width, it.height) }
                .orEmpty(),
            frontFacing = characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT,
            zoomRange = zoomRangeOf(characteristics),
        )
    }

    fun codecAvailability(): CodecAvailability = CodecAvailability(
        h264 = support(EncoderCodec.H264),
        hevc = support(EncoderCodec.HEVC),
    )

    /** The highest frame rate any encoder of [codec] can do at [size], or 0 if none handles the size. */
    fun maxEncoderFps(codec: EncoderCodec, size: VideoDimension): Int =
        encoders(codec).maxOfOrNull { info ->
            try {
                val video = info.getCapabilitiesForType(codec.mime).videoCapabilities
                if (video != null && video.isSizeSupported(size.width, size.height)) {
                    video.getSupportedFrameRatesFor(size.width, size.height).upper.toInt()
                } else {
                    0
                }
            } catch (_: IllegalArgumentException) {
                0
            }
        } ?: 0

    /**
     * What the device manufacturer recommends as bitrate for [codec] on this camera, taken from the
     * camcorder profiles (the ones the stock camera app uses).
     */
    fun referenceBitrate(cameraId: String, codec: EncoderCodec): ReferenceBitrate? {
        val wanted = when (codec) {
            EncoderCodec.H264 -> MediaRecorder.VideoEncoder.H264
            EncoderCodec.HEVC -> MediaRecorder.VideoEncoder.HEVC
        }
        val qualities = intArrayOf(
            CamcorderProfile.QUALITY_1080P,
            CamcorderProfile.QUALITY_720P,
            CamcorderProfile.QUALITY_2160P,
            CamcorderProfile.QUALITY_480P,
        )
        for (quality in qualities) {
            val profiles = try {
                CamcorderProfile.getAll(cameraId, quality)
            } catch (_: RuntimeException) {
                null
            } ?: continue
            val match = profiles.videoProfiles.firstOrNull { it.codec == wanted } ?: continue
            return ReferenceBitrate(match.bitrate, VideoDimension(match.width, match.height), match.frameRate)
        }
        return null
    }

    private fun support(codec: EncoderCodec): CodecSupport {
        val found = encoders(codec)
        return CodecSupport(supported = found.isNotEmpty(), hardware = found.any { it.isHardwareAccelerated })
    }

    private fun encoders(codec: EncoderCodec): List<MediaCodecInfo> =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(codec.mime, ignoreCase = true) }
        }
}
