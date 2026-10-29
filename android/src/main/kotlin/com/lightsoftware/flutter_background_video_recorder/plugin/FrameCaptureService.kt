package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream

/**
 * Foreground service that keeps a camera open and publishes its frames to [FrameSessionHolder]'s
 * sink until it is told to stop. It records nothing: it is the producer of the app's frame stream.
 *
 * The camera and its callbacks live on the main thread; frames arrive on a thread of their own
 * and are converted there. If nobody listens, or the app falls behind, a frame is dropped before
 * any work is done on it.
 */
class FrameCaptureService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val holder get() = FrameSessionHolder.holder

    private var config: FrameSessionConfig? = null
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var request: CaptureRequest.Builder? = null

    private var active = false
    private var sensorOrientation = 0
    private var frontFacing = false
    private var zoomRange = ZoomRange.NONE
    private var zoom = 1f

    /** The native slots frames are written into. Created on the first frame, on the frame thread. */
    @Volatile
    private var ring: FrameRing? = null

    @Volatile
    private var released = false

    // Only touched on the frame thread.
    private var nv21: ByteArray? = null
    private var lastDeliveredNs = 0L
    private var rotation = 0
    private var rotationCheckedAt = 0L

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_STOP -> closeSession()
            ACTION_START -> {
                val sessionConfig = FrameSessionConfig.fromIntent(intent)
                // startForegroundService() obliges us to call startForeground() within seconds, so
                // do it before anything else, also when we are about to refuse the request.
                if (!enterForeground(sessionConfig)) {
                    holder.failed("foreground_service_failed", "Could not start the camera foreground service.")
                    stopSelf()
                } else if (sessionConfig == null) {
                    fail("invalid_arguments", "The frame session request was incomplete.")
                } else if (!active) {
                    begin(sessionConfig)
                }
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (active) release(notifyClosed = true)
        if (instance === this) instance = null
        super.onDestroy()
    }

    // region Public API for the plugin (main thread only)

    /** Closes the session on request of the app or the notification's Stop action. */
    internal fun closeSession() {
        if (active) release(notifyClosed = true) else holder.closed()
        shutdown()
    }

    /**
     * Zooms to [ratio], limited to what the camera supports, and returns what was applied. Null
     * when the camera is not running.
     */
    internal fun setZoom(ratio: Float): Float? {
        if (!active) return null
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

    // endregion

    private fun enterForeground(config: FrameSessionConfig?): Boolean {
        val notification = RecorderNotifications.foreground(
            this,
            title = config?.notificationTitle.orEmpty(),
            text = config?.notificationText.orEmpty(),
            stopService = FrameCaptureService::class.java,
            stopAction = ACTION_STOP,
        )
        return try {
            ServiceCompat.startForeground(
                this,
                RecorderNotifications.FRAME_FOREGROUND_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            )
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing permission for the camera foreground service", e)
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) extends IllegalStateException.
            Log.e(TAG, "Foreground service start not allowed", e)
            false
        }
    }

    // region Camera

    @SuppressLint("MissingPermission") // Checked right below.
    private fun begin(sessionConfig: FrameSessionConfig) {
        if (holder.closeRequested) return closeSession()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            return fail("permission_denied", "The camera permission is required.")
        }
        val capabilities = CameraCapabilitiesProvider.query(this, sessionConfig.camera)
            ?: return fail("camera_not_found", "The chosen camera is not available.")
        try {
            FrameRingJni.load()
        } catch (e: UnsatisfiedLinkError) {
            return fail("recording_failed", "The native frame library could not be loaded.", e)
        }
        config = sessionConfig
        active = true
        released = false
        sensorOrientation = capabilities.sensorOrientation
        frontFacing = capabilities.frontFacing
        zoomRange = capabilities.zoomRange
        zoom = zoomRange.clamp(sessionConfig.frame.initialZoom)

        val frames = HandlerThread("fbvr-frames").also { it.start() }
        thread = frames
        val dimension = sessionConfig.dimension
        val imageReader = ImageReader.newInstance(dimension.width, dimension.height, ImageFormat.YUV_420_888, MAX_IMAGES)
        reader = imageReader
        imageReader.setOnImageAvailableListener({ source -> onImageAvailable(source) }, Handler(frames.looper))

        try {
            getSystemService(CameraManager::class.java).openCamera(capabilities.cameraId, cameraStateCallback, mainHandler)
        } catch (e: SecurityException) {
            fail("permission_denied", "Camera access was denied.", e)
        } catch (e: CameraAccessException) {
            fail("camera_unavailable", "The camera is disabled or in use by another app.", e)
        }
    }

    private val cameraStateCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(device: CameraDevice) {
            if (!active) {
                device.close()
                return
            }
            camera = device
            try {
                startCaptureSession(device)
            } catch (e: CameraAccessException) {
                fail("camera_unavailable", "Could not start the capture session.", e)
            } catch (e: RuntimeException) {
                fail("camera_error", "Could not start the capture session: ${e.message}", e)
            }
        }

        override fun onDisconnected(device: CameraDevice) {
            device.close()
            if (camera === device) camera = null
            if (active) fail("camera_disconnected", "The camera was disconnected.")
        }

        override fun onError(device: CameraDevice, error: Int) {
            device.close()
            if (camera === device) camera = null
            if (active) fail("camera_error", "The camera reported error $error.")
        }
    }

    private fun startCaptureSession(device: CameraDevice) {
        val surface = reader?.surface ?: return
        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(surface)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
        }
        request = builder
        device.createCaptureSession(
            SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                listOf(OutputConfiguration(surface)),
                ContextCompat.getMainExecutor(this),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(configured: CameraCaptureSession) {
                        if (!active) {
                            configured.close()
                            return
                        }
                        session = configured
                        try {
                            configured.setRepeatingRequest(builder.build(), null, mainHandler)
                            val sessionConfig = config ?: return
                            holder.opened(
                                FrameSessionInfo(
                                    cameraId = device.id,
                                    width = sessionConfig.dimension.width,
                                    height = sessionConfig.dimension.height,
                                    format = sessionConfig.frame.format,
                                ),
                            )
                            Log.i(TAG, "Frame session started")
                        } catch (e: CameraAccessException) {
                            fail("camera_unavailable", "Could not start the repeating request.", e)
                        } catch (e: RuntimeException) {
                            fail("camera_error", "Could not start the camera: ${e.message}", e)
                        }
                    }

                    override fun onConfigureFailed(failed: CameraCaptureSession) {
                        failed.close()
                        if (active) fail("unsupported_configuration", "The camera cannot deliver frames of this size.")
                    }
                },
            ),
        )
    }

    // endregion

    // region Frames (frame thread)

    private fun onImageAvailable(source: ImageReader) {
        val image = source.acquireLatestImage() ?: return
        try {
            val sessionConfig = config ?: return
            if (!shouldDeliver(image.timestamp, sessionConfig.frame.maxFps)) return
            val frame = write(image, sessionConfig) ?: return
            // The hub drops its reference after the subscribers saw the frame; a frame it refuses
            // is still ours to release.
            if (!holder.hub.publish(frame)) frame.lease.release()
        } catch (e: RuntimeException) {
            Log.w(TAG, "Dropped a frame that could not be written", e)
        } finally {
            image.close()
        }
    }

    /** Skips the frame, before any work is done, when nobody can take it or it is too soon. */
    private fun shouldDeliver(timestampNs: Long, maxFps: Int?): Boolean {
        if (!holder.hub.canAccept) return false
        if (maxFps != null) {
            val minInterval = 1_000_000_000L / maxFps
            // A little slack so that a camera running at exactly maxFps is not halved by jitter.
            if (timestampNs - lastDeliveredNs < minInterval * 9 / 10) return false
        }
        lastDeliveredNs = timestampNs
        return true
    }

    /**
     * Puts the picture into a free native slot and describes it. The only copy of the pixels
     * happens here, in native code; nothing is allocated on the Java heap per frame except for JPEG.
     * Null when there is no free slot, or the picture could not be written.
     */
    private fun write(image: Image, sessionConfig: FrameSessionConfig): RawFrameData? {
        val planes = image.planes
        if (planes.size != 3) return null
        val width = image.width
        val height = image.height
        val format = sessionConfig.frame.format
        val frameRing = ring ?: createRing(image, sessionConfig) ?: return null
        val lease = frameRing.acquire() ?: return null
        val layouts = ArrayList<PlaneLayout>(3)
        val written = try {
            when (format) {
                RawFrameFormat.YUV420 -> {
                    var offset = 0
                    var ok = true
                    for (plane in planes) {
                        val length = plane.buffer.limit()
                        ok = ok && FrameRingJni.nativeCopyBuffer(frameRing.id, lease.slot, offset, plane.buffer, 0, length)
                        layouts += PlaneLayout(offset, length, plane.rowStride, plane.pixelStride)
                        offset += alignUp(length)
                    }
                    ok
                }
                RawFrameFormat.RGBA -> {
                    layouts += PlaneLayout(0, width * height * 4, width * 4, 4)
                    FrameRingJni.nativeYuvToRgba(
                        frameRing.id, lease.slot, 0,
                        planes[0].buffer, planes[0].rowStride, planes[0].pixelStride,
                        planes[1].buffer, planes[1].rowStride, planes[1].pixelStride,
                        planes[2].buffer, planes[2].rowStride, planes[2].pixelStride,
                        width, height,
                    )
                }
                RawFrameFormat.JPEG -> writeJpeg(frameRing, lease, planes, width, height, sessionConfig.frame.jpegQuality, layouts)
            }
        } catch (e: RuntimeException) {
            false
        }
        if (!written) {
            lease.release()
            return null
        }
        return RawFrameData(
            format, width, height, currentRotation(), image.timestamp, lease, layouts, frameRing.dropped,
        )
    }

    private fun writeJpeg(
        frameRing: FrameRing,
        lease: FrameLease,
        planes: Array<Image.Plane>,
        width: Int,
        height: Int,
        quality: Int,
        layouts: MutableList<PlaneLayout>,
    ): Boolean {
        val size = width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)
        // Reused from frame to frame.
        val buffer = nv21?.takeIf { it.size == size } ?: ByteArray(size).also { nv21 = it }
        val converted = FrameRingJni.nativeYuvToNv21(
            planes[0].buffer, planes[0].rowStride, planes[0].pixelStride,
            planes[1].buffer, planes[1].rowStride, planes[1].pixelStride,
            planes[2].buffer, planes[2].rowStride, planes[2].pixelStride,
            width, height, buffer,
        )
        if (!converted) return false
        val out = ByteArrayOutputStream(size / 8)
        android.graphics.YuvImage(buffer, ImageFormat.NV21, width, height, null)
            .compressToJpeg(Rect(0, 0, width, height), quality, out)
        val jpeg = out.toByteArray()
        layouts += PlaneLayout(0, jpeg.size, 0, 1)
        return FrameRingJni.nativeCopyBytes(frameRing.id, lease.slot, 0, jpeg, jpeg.size)
    }

    /** Sizes the slots from the first picture: all of its planes, or the converted picture. */
    private fun createRing(image: Image, sessionConfig: FrameSessionConfig): FrameRing? {
        val width = image.width
        val height = image.height
        val capacity = when (sessionConfig.frame.format) {
            RawFrameFormat.YUV420 -> image.planes.sumOf { alignUp(it.buffer.limit()).toLong() }
            RawFrameFormat.RGBA -> width.toLong() * height * 4
            // A JPEG is far smaller than the picture; a frame that is not is dropped.
            RawFrameFormat.JPEG -> maxOf(width.toLong() * height * 3 / 2, MIN_JPEG_CAPACITY)
        }
        val created = FrameRing.create(RING_SLOTS, capacity) ?: return null
        ring = created
        if (released) {
            // The session ended while the ring was being made.
            created.close()
            ring = null
            return null
        }
        return created
    }

    private fun alignUp(length: Int) = (length + SLOT_ALIGNMENT - 1) / SLOT_ALIGNMENT * SLOT_ALIGNMENT

    /** How far the picture must be turned to be upright, looked up at most a few times a second. */
    private fun currentRotation(): Int {
        val now = SystemClock.elapsedRealtime()
        if (now - rotationCheckedAt > ROTATION_CHECK_MS) {
            rotationCheckedAt = now
            rotation = videoOrientationHint(sensorOrientation, displayRotationDegrees(this), frontFacing)
        }
        return rotation
    }

    // endregion

    // region Finishing

    /** Ends the session because of a failure, telling whoever is waiting or listening. */
    private fun fail(code: String, message: String, cause: Throwable? = null) {
        Log.e(TAG, "$code: $message", cause)
        release(notifyClosed = false)
        holder.failed(code, message)
        shutdown()
    }

    /** Releases the camera and the frame thread. With [notifyClosed] the subscribers are told it is over. */
    private fun release(notifyClosed: Boolean) {
        active = false
        reader?.setOnImageAvailableListener(null, null)
        try {
            session?.stopRepeating()
        } catch (_: CameraAccessException) {
        } catch (_: IllegalStateException) {
        }
        session?.close()
        session = null
        camera?.close()
        camera = null
        reader?.close()
        reader = null
        request = null
        thread?.quitSafely()
        thread = null
        config = null
        // Frames still held by the app keep their slots; the memory is freed when they are released.
        released = true
        ring?.close()
        ring = null
        if (notifyClosed) holder.closed()
    }

    private fun shutdown() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // endregion

    companion object {
        private const val TAG = "BackgroundVideoRecorder"
        private const val MAX_IMAGES = 3

        /** One being written, one in transit, one held by the app, and a spare. */
        private const val RING_SLOTS = 4
        private const val SLOT_ALIGNMENT = 64
        private const val MIN_JPEG_CAPACITY = 256L * 1024
        private const val ROTATION_CHECK_MS = 250L

        internal const val ACTION_START = "com.lightsoftware.flutter_background_video_recorder.FRAMES_START"
        internal const val ACTION_STOP = "com.lightsoftware.flutter_background_video_recorder.FRAMES_STOP"

        /** The running service, if any. Only touch it from the main thread. */
        @Volatile
        internal var instance: FrameCaptureService? = null
            private set
    }
}
