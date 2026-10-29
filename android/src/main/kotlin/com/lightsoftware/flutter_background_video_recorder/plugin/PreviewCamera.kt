package com.lightsoftware.flutter_background_video_recorder.plugin

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.SessionConfiguration
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.core.content.ContextCompat

/**
 * Keeps the camera open for the on-screen viewfinder while nothing is being recorded, so the user
 * can frame the shot. It is only for the app being visible: no foreground service is involved, and
 * Android takes the camera away when the app goes to the background, which is just a normal stop.
 * While recording, the service owns the camera instead and feeds the same [PreviewRelay].
 *
 * Main thread only.
 */
internal class PreviewCamera(
    private val context: Context,
    private val zoomRange: ZoomRange,
    initialZoom: Float,
    private val onLost: () -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var inputSurface: Surface? = null
    private var request: CaptureRequest.Builder? = null
    private var stopped = false

    /** The zoom ratio in use, limited to what the camera supports. */
    var zoom = zoomRange.clamp(initialZoom)
        private set

    val isRunning: Boolean get() = !stopped

    @SuppressLint("MissingPermission") // Checked by the caller; a missing permission is handled below.
    fun start(cameraId: String, bufferSize: VideoDimension) {
        inputSurface = PreviewRelay.createInputSurface(bufferSize.width, bufferSize.height)
        try {
            context.getSystemService(CameraManager::class.java).openCamera(cameraId, stateCallback, mainHandler)
        } catch (e: SecurityException) {
            lose("Camera permission missing", e)
        } catch (e: CameraAccessException) {
            lose("Camera unavailable", e)
        }
    }

    /** Changes the zoom and returns the ratio that was applied. */
    fun setZoom(ratio: Float): Float {
        zoom = zoomRange.clamp(ratio)
        val builder = request ?: return zoom
        val running = session ?: return zoom
        builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
        try {
            running.setRepeatingRequest(builder.build(), null, mainHandler)
        } catch (e: CameraAccessException) {
            Log.w(TAG, "Could not change the zoom", e)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "Could not change the zoom", e)
        }
        return zoom
    }

    fun stop() {
        if (stopped) return
        stopped = true
        request = null
        session?.close()
        session = null
        device?.close()
        device = null
        val surface = inputSurface
        inputSurface = null
        PreviewRelay.releaseInputSurface(only = surface)
    }

    private fun lose(reason: String, cause: Throwable? = null) {
        Log.i(TAG, "Viewfinder stopped: $reason", cause)
        val wasRunning = !stopped
        stop()
        if (wasRunning) onLost()
    }

    private val stateCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(opened: CameraDevice) {
            if (stopped) {
                opened.close()
                return
            }
            device = opened
            val surface = inputSurface ?: return lose("No input surface")
            try {
                val builder = opened.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                    addTarget(surface)
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                    set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
                }
                request = builder
                opened.createCaptureSession(
                    SessionConfiguration(
                        SessionConfiguration.SESSION_REGULAR,
                        listOf(PreviewRelay.outputConfiguration(surface)),
                        ContextCompat.getMainExecutor(context),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(configured: CameraCaptureSession) {
                                if (stopped) {
                                    configured.close()
                                    return
                                }
                                session = configured
                                try {
                                    configured.setRepeatingRequest(builder.build(), null, mainHandler)
                                } catch (e: CameraAccessException) {
                                    lose("Could not start the viewfinder", e)
                                }
                            }

                            override fun onConfigureFailed(failed: CameraCaptureSession) {
                                failed.close()
                                lose("Could not configure the viewfinder")
                            }
                        },
                    ),
                )
            } catch (e: CameraAccessException) {
                lose("Could not open a viewfinder session", e)
            } catch (e: RuntimeException) {
                lose("Could not open a viewfinder session", e)
            }
        }

        override fun onDisconnected(disconnected: CameraDevice) {
            disconnected.close()
            if (device === disconnected) device = null
            lose("Camera disconnected")
        }

        override fun onError(failed: CameraDevice, error: Int) {
            failed.close()
            if (device === failed) device = null
            lose("Camera error $error")
        }
    }

    private companion object {
        const val TAG = "BackgroundVideoRecorder"
    }
}
