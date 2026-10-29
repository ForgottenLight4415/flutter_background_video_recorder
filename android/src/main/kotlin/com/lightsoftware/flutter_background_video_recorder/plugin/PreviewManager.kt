package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.view.TextureRegistry

/**
 * Owns the on-screen preview: the Flutter texture, and what feeds it.
 *
 * While nothing is recorded a [PreviewCamera] (the viewfinder) feeds the [PreviewRelay]. When a
 * recording starts the viewfinder lets go of the camera and the service feeds the relay instead
 * (if the recording asked for a preview). The Flutter texture is the same throughout.
 *
 * Hiding the preview is the app unmounting its widget, which ends in [stop]: the Flutter texture
 * goes away and the relay drops frames. The recording is never touched.
 *
 * Main thread only.
 */
internal class PreviewManager(
    private val context: Context,
    private val textures: TextureRegistry,
    private val emit: (Map<String, Any?>) -> Unit,
) : RecorderStateListener {

    class PreviewException(val code: String, message: String) : Exception(message)

    private class Active(
        val producer: TextureRegistry.SurfaceProducer,
        val mirrorFront: Boolean,
        val wantedAspect: Double?,
        val capabilities: CameraCapabilities,
        var buffer: VideoDimension,
        /** The zoom the viewfinder starts with, and the last one set while it ran. */
        var zoom: Float,
    ) {
        /** The camera's real facing, which decides how its picture is turned and mirrored. */
        val frontFacing: Boolean get() = capabilities.frontFacing

        /** Total clockwise turn from the camera's buffer to an upright picture. */
        var rotation = 0

        /**
         * The part of [rotation] the relay has to apply itself. The camera service already turns
         * preview buffers by the sensor orientation (that is in the SurfaceTexture's transform
         * matrix), so what is left is only for how the display is held.
         */
        var correction = 0
        var upright = VideoDimension(1, 1)
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var active: Active? = null
    private var camera: PreviewCamera? = null
    private val displayManager = context.getSystemService(DisplayManager::class.java)

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            mainHandler.post { refresh() }
        }
    }

    init {
        RecorderStateHolder.addListener(this)
        PreviewRelay.inputSizeListener = { size -> mainHandler.post { onInputSize(size) } }
    }

    /** True while the viewfinder camera is open, which makes the camera unavailable to a frame session. */
    val holdsCamera: Boolean get() = camera?.isRunning == true

    /**
     * Zooms the viewfinder and returns the ratio applied, or null when the viewfinder camera is not
     * running.
     */
    fun setZoom(ratio: Float): Float? {
        val preview = active ?: return null
        val viewfinder = camera?.takeIf { it.isRunning } ?: return null
        return viewfinder.setZoom(ratio).also { preview.zoom = it }
    }

    /**
     * Starts (or restarts) the preview for the chosen camera. [wantedAspect] is the aspect ratio
     * of the video that will be recorded, so the preview shows what it will contain.
     * Returns what Flutter needs to show it.
     */
    fun start(
        choice: CameraChoice,
        wantedAspect: Double?,
        mirrorFront: Boolean,
        initialZoom: Float = 1f,
    ): Map<String, Any?> {
        stopInternal()
        val capabilities = CameraCapabilitiesProvider.query(context, choice)
            ?: throw PreviewException(
                "camera_not_found",
                if (choice.cameraId != null) "The chosen camera is not available." else "No ${if (choice.frontFacing) "front" else "rear"} camera available.",
            )
        val buffer = choosePreviewDimension(capabilities.previewSizes, wantedAspect)
            ?: throw PreviewException("camera_unavailable", "The camera offers no preview size.")

        val producer = textures.createSurfaceProducer()
        val preview = Active(producer, mirrorFront, wantedAspect, capabilities, buffer, capabilities.zoomRange.clamp(initialZoom))
        updateOrientation(preview)
        producer.setSize(preview.upright.width, preview.upright.height)
        producer.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                // Flutter may destroy the surface (for example when the app is backgrounded) and
                // make a new one later. The relay shields the camera from that.
                override fun onSurfaceAvailable() {
                    mainHandler.post { if (active === preview) attach(preview) }
                }

                override fun onSurfaceCleanup() {
                    PreviewRelay.detach()
                }
            },
        )
        active = preview
        attach(preview)
        displayManager.registerDisplayListener(displayListener, mainHandler)
        return info(preview, feed(preview))
    }

    /** Ends the preview with the given texture. Safe to call twice. */
    fun stop(textureId: Long) {
        if (active?.producer?.id() == textureId) stopInternal()
    }

    fun dispose() {
        stopInternal()
        RecorderStateHolder.removeListener(this)
        PreviewRelay.inputSizeListener = null
    }

    // region Recorder state

    override fun onStateChanged(status: RecorderStatus, errorCode: String?, errorMessage: String?, video: RecordedMedia?) {
        val preview = active ?: return
        when (status) {
            // The service is about to take the camera: let go of it first.
            RecorderStatus.INITIALIZING -> {
                camera?.stop()
                camera = null
                notifyChanged(preview, live = PreviewRelay.fedByCamera)
            }
            // The recording is over and the service has released the relay: show the viewfinder again.
            RecorderStatus.STOPPED, RecorderStatus.ERROR -> notifyChanged(preview, feed(preview))
            RecorderStatus.RECORDING -> notifyChanged(preview, PreviewRelay.fedByCamera)
        }
    }

    // endregion

    private fun feed(preview: Active): Boolean {
        val status = RecorderStateHolder.status
        if (status == RecorderStatus.RECORDING || status == RecorderStatus.INITIALIZING) {
            // The service feeds the relay, if the recording was started with a preview.
            return PreviewRelay.fedByCamera
        }
        if (camera?.isRunning == true) return true
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        val viewfinder = PreviewCamera(context, preview.capabilities.zoomRange, preview.zoom) {
            mainHandler.post {
                camera = null
                active?.let { notifyChanged(it, live = false) }
            }
        }
        camera = viewfinder
        viewfinder.start(preview.capabilities.cameraId, preview.buffer)
        return true
    }

    /** The size of the camera feed changed (a recording made its own input surface). */
    private fun onInputSize(size: VideoDimension) {
        val preview = active ?: return
        if (preview.buffer == size) return
        preview.buffer = size
        updateOrientation(preview)
        preview.producer.setSize(preview.upright.width, preview.upright.height)
        attach(preview)
        notifyChanged(preview, live = PreviewRelay.fedByCamera)
    }

    /** The display was rotated: the picture needs turning, and its upright size may change. */
    private fun refresh() {
        val preview = active ?: return
        val before = Triple(preview.rotation, preview.correction, preview.upright)
        updateOrientation(preview)
        if (before == Triple(preview.rotation, preview.correction, preview.upright)) return
        preview.producer.setSize(preview.upright.width, preview.upright.height)
        attach(preview)
        notifyChanged(preview, live = PreviewRelay.fedByCamera || camera?.isRunning == true)
    }

    private fun updateOrientation(preview: Active) {
        val display = displayRotationDegrees(context)
        preview.rotation = videoOrientationHint(preview.capabilities.sensorOrientation, display, preview.frontFacing)
        preview.correction = videoOrientationHint(0, display, preview.frontFacing)
        preview.upright = uprightPreviewSize(preview.buffer, preview.rotation)
    }

    private fun attach(preview: Active) {
        try {
            PreviewRelay.attach(
                preview.producer.surface,
                preview.producer.width,
                preview.producer.height,
                preview.correction,
                mirror = preview.frontFacing && preview.mirrorFront,
            )
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not attach the preview", e)
        }
    }

    private fun stopInternal() {
        camera?.stop()
        camera = null
        val preview = active ?: return
        active = null
        PreviewRelay.detach()
        preview.producer.setCallback(null)
        preview.producer.release()
        displayManager.unregisterDisplayListener(displayListener)
    }

    private fun info(preview: Active, live: Boolean): Map<String, Any?> = mapOf(
        "textureId" to preview.producer.id(),
        "width" to preview.upright.width,
        "height" to preview.upright.height,
        "active" to live,
    )

    private fun notifyChanged(preview: Active, live: Boolean) {
        emit(mapOf("type" to "preview") + info(preview, live))
    }

    private companion object {
        const val TAG = "BackgroundVideoRecorder"
    }
}
