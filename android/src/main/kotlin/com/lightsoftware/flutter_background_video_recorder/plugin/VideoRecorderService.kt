package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaRecorder
import android.os.PowerManager
import android.os.StatFs
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.util.Range
import android.view.Surface
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.io.IOException

/**
 * Foreground service that owns a recording from start to finish.
 *
 * Everything (Camera2 callbacks, plugin calls, state changes) runs on the main thread, so the
 * fields below need no locking. The service keeps recording when the Activity or the Flutter
 * engine goes away; it is stopped by [stopRecording], the notification's Stop action, or a failure.
 */
class VideoRecorderService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())

    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var recorder: MediaRecorder? = null
    private var output: MediaOutput? = null

    /** True from the moment a recording begins until it is finished or has failed. */
    private var active = false

    /** True once [MediaRecorder.start] succeeded, so that stop() is valid. */
    private var recordingStarted = false

    /** True if a position was stored in the video being recorded. */
    private var locationEmbedded = false

    /** The relay's input, when this recording also feeds an on-screen preview. */
    private var previewSurface: Surface? = null

    private var selectedStabilization = false
    private var aeRange: FpsRange? = null

    /** The capture request that keeps running, so that the zoom can be changed while recording. */
    private var captureRequest: CaptureRequest.Builder? = null
    private var zoomRange = ZoomRange.NONE
    private var zoom = 1f

    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private var thermalWarned = false

    private class CameraSelection(
        val id: String,
        val orientationHint: Int,
    )

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent means the system restarted us after the process died. There is nothing
        // to resume (the recording was lost with the process), so do not stay around.
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_STOP -> {
                if (active) stopRecording() else shutdown()
            }
            ACTION_START -> {
                // startForegroundService() obliges us to call startForeground() within seconds,
                // so do it before anything else, also when we are about to refuse the request.
                val config = RecordingConfig.fromIntent(intent)
                if (!enterForeground(config)) {
                    RecorderStateHolder.update(
                        RecorderStatus.ERROR,
                        "foreground_service_failed",
                        "Could not start the recording foreground service.",
                    )
                    stopSelf()
                } else if (config == null) {
                    fail("recording_failed", "The recording request was incomplete.")
                } else if (!active) {
                    beginRecording(config)
                }
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // Normally everything is finished already. If the system tears us down mid-recording,
        // keep what was recorded so far.
        if (active) {
            finishRecording(save = true)
            RecorderStateHolder.update(RecorderStatus.STOPPED)
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    // region Public API for the plugin (main thread only)

    /**
     * Zooms the recording to [ratio], limited to what the camera supports, and returns what was
     * applied. Null when no video recording is running. Changing the zoom re-sends the repeating
     * capture request; the recorder is not touched.
     */
    internal fun setZoom(ratio: Float): Float? {
        if (!active || RecorderStateHolder.activeMode != RecordingMode.VIDEO) return null
        zoom = zoomRange.clamp(ratio)
        val builder = captureRequest ?: return zoom
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

    /** Stops an active recording and returns the saved media, or null if it could not be saved. */
    internal fun stopRecording(): RecordedMedia? {
        if (!active) return null
        val video = finishRecording(save = true)
        if (video != null) {
            RecorderStateHolder.update(RecorderStatus.STOPPED)
        } else {
            RecorderStateHolder.update(
                RecorderStatus.ERROR,
                "stop_failed",
                "The recording contained no valid data and was discarded.",
            )
        }
        shutdown()
        return video
    }

    // endregion

    // region Foreground notification

    private fun enterForeground(config: RecordingConfig?): Boolean {
        val notification = RecorderNotifications.foreground(
            this,
            title = config?.notificationTitle.orEmpty(),
            text = config?.notificationText.orEmpty(),
        )
        return try {
            // An audio-only recording must not hold the camera type: it would show the camera
            // privacy indicator and need the camera permission for no reason.
            val type = if (config?.mode == RecordingMode.AUDIO) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            ServiceCompat.startForeground(this, RecorderNotifications.FOREGROUND_ID, notification, type)
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing permission for the camera/microphone foreground service", e)
            false
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) extends IllegalStateException.
            Log.e(TAG, "Foreground service start not allowed", e)
            false
        }
    }

    // endregion

    // region Recording

    private fun beginRecording(config: RecordingConfig) {
        active = true
        recordingStarted = false
        RecorderNotifications.cancelFailureAlert(this)
        RecorderStateHolder.update(RecorderStatus.INITIALIZING)
        try {
            when (config.mode) {
                RecordingMode.VIDEO -> beginVideo(config)
                RecordingMode.AUDIO -> beginAudio(config)
            }
        } catch (e: SecurityException) {
            fail("permission_denied", "Camera or microphone access was denied.", e)
        } catch (e: CameraAccessException) {
            fail("camera_unavailable", "The camera is disabled or in use by another app.", e)
        } catch (e: IOException) {
            fail("storage_error", "Could not create the output file: ${e.message}", e)
        } catch (e: RuntimeException) {
            fail("recording_failed", "Could not prepare the recorder: ${e.message}", e)
        }
    }

    // The camera permission is checked first thing; a revoked one is a SecurityException, which
    // beginRecording turns into a "permission_denied" failure.
    @SuppressLint("MissingPermission")
    private fun beginVideo(config: RecordingConfig) {
        val video = config.video ?: return fail("recording_failed", "The recording request was incomplete.")
        if (!isGranted(Manifest.permission.CAMERA) || !isGranted(Manifest.permission.RECORD_AUDIO)) {
            return fail("permission_denied", "Camera and microphone permissions are required.")
        }
        val capabilities = CameraCapabilitiesProvider.query(this, config.camera)
            ?: return fail("camera_not_found", config.camera.notFoundMessage())
        val selection = CameraSelection(
            id = capabilities.cameraId,
            orientationHint = videoOrientationHint(
                capabilities.sensorOrientation,
                displayRotationDegrees(this),
                capabilities.frontFacing,
            ),
        )
        zoomRange = capabilities.zoomRange
        zoom = zoomRange.clamp(config.initialZoom)
        selectedStabilization = capabilities.stabilization
        aeRange = chooseAeRange(capabilities.aeRanges, video.frameRate)

        val freeBytes = availableStorageBytes()
        if (freeBytes < MIN_FREE_BYTES) {
            return fail("storage_full", "Not enough free storage to record a video.")
        }

        if (config.preview) {
            // The preview should show what the video contains, so it has the video's aspect ratio.
            val aspect = video.dimension.width.toDouble() / video.dimension.height
            choosePreviewDimension(capabilities.previewSizes, aspect)?.let {
                previewSurface = PreviewRelay.createInputSurface(it.width, it.height)
            }
        }

        val destination = MediaOutput.create(this, MediaKind.VIDEO, config.folderName)
        output = destination
        val mediaRecorder = createMediaRecorder()
        recorder = mediaRecorder
        configureMediaRecorder(
            mediaRecorder,
            destination,
            video,
            selection,
            config.location,
            maxFileBytes = freeBytes - STORAGE_MARGIN_BYTES,
        )
        watchThermalStatus()

        getSystemService(CameraManager::class.java)
            .openCamera(selection.id, cameraStateCallback, mainHandler)
    }

    /** Audio-only: no camera and no capture session, the recorder starts right away. */
    private fun beginAudio(config: RecordingConfig) {
        if (!isGranted(Manifest.permission.RECORD_AUDIO)) {
            return fail("permission_denied", "The microphone permission is required.")
        }
        val freeBytes = availableStorageBytes()
        if (freeBytes < MIN_FREE_BYTES) {
            return fail("storage_full", "Not enough free storage to record audio.")
        }

        val destination = MediaOutput.create(this, MediaKind.AUDIO, config.folderName)
        output = destination
        val mediaRecorder = createMediaRecorder()
        recorder = mediaRecorder
        mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
        mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        destination.applyTo(mediaRecorder)
        mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        configureAudioQuality(mediaRecorder)
        limitAndWatch(mediaRecorder, maxFileBytes = freeBytes - STORAGE_MARGIN_BYTES)
        mediaRecorder.prepare()
        mediaRecorder.start()
        recordingStarted = true
        RecorderStateHolder.update(RecorderStatus.RECORDING)
        Log.i(TAG, "Audio recording started")
    }

    private fun createMediaRecorder(): MediaRecorder = MediaRecorder(this)

    private fun configureMediaRecorder(
        target: MediaRecorder,
        destination: MediaOutput,
        video: ResolvedVideo,
        selection: CameraSelection,
        location: Coordinates?,
        maxFileBytes: Long,
    ) {
        target.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        target.setAudioSource(MediaRecorder.AudioSource.MIC)
        target.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        destination.applyTo(target)
        locationEmbedded = false
        if (location != null && isValidCoordinates(location.latitude, location.longitude)) {
            target.setLocation(location.latitude.toFloat(), location.longitude.toFloat())
            locationEmbedded = true
        }
        target.setVideoEncodingBitRate(video.bitrate)
        target.setVideoFrameRate(video.frameRate)
        target.setVideoSize(video.dimension.width, video.dimension.height)
        target.setVideoEncoder(
            when (video.codec) {
                EncoderCodec.H264 -> MediaRecorder.VideoEncoder.H264
                EncoderCodec.HEVC -> MediaRecorder.VideoEncoder.HEVC
            },
        )
        target.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        configureAudioQuality(target)
        target.setOrientationHint(selection.orientationHint)
        limitAndWatch(target, maxFileBytes)
        target.prepare()
    }

    // Without these the platform records 8 kHz mono at about 12 kbps, which sounds like a phone call.
    private fun configureAudioQuality(target: MediaRecorder) {
        target.setAudioSamplingRate(AUDIO_SAMPLE_RATE)
        target.setAudioEncodingBitRate(AUDIO_BIT_RATE)
        target.setAudioChannels(1)
    }

    /** Caps the file size and reacts to the recorder's own failures. */
    private fun limitAndWatch(target: MediaRecorder, maxFileBytes: Long) {
        // Stop cleanly (and keep the recording) shortly before the disk is full.
        target.setMaxFileSize(maxFileBytes)
        target.setOnInfoListener { _, what, _ ->
            if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED && active) {
                fail("storage_full", "The device ran out of storage.", save = recordingStarted)
            }
        }
        target.setOnErrorListener { _, what, extra ->
            if (active) {
                // A full disk surfaces as a generic I/O error, so tell the user the real reason.
                if (availableStorageBytes() < LOW_STORAGE_BYTES) {
                    fail("storage_full", "The device ran out of storage.", save = recordingStarted)
                } else {
                    fail("recording_failed", "The recorder reported error $what/$extra.", save = recordingStarted)
                }
            }
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
                startCaptureSession(device, withPreview = previewSurface != null)
            } catch (e: CameraAccessException) {
                fail("camera_unavailable", "Could not start the capture session.", e)
            } catch (e: RuntimeException) {
                fail("recording_failed", "Could not start the capture session: ${e.message}", e)
            }
        }

        override fun onDisconnected(device: CameraDevice) {
            device.close()
            if (camera === device) camera = null
            if (active) fail("camera_disconnected", "The camera was disconnected.", save = recordingStarted)
        }

        override fun onError(device: CameraDevice, error: Int) {
            device.close()
            if (camera === device) camera = null
            if (active) fail("camera_error", "The camera reported error $error.", save = recordingStarted)
        }
    }

    private fun startCaptureSession(device: CameraDevice, withPreview: Boolean) {
        val mediaRecorder = recorder ?: return
        val stabilization = selectedStabilization
        val surface = mediaRecorder.surface
        val preview = if (withPreview) previewSurface else null
        val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
            addTarget(surface)
            preview?.let { addTarget(it) }
            set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            aeRange?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(it.lower, it.upper)) }
            if (stabilization) {
                set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)
            }
        }
        captureRequest = request
        val configuration = SessionConfiguration(
            SessionConfiguration.SESSION_REGULAR,
            listOfNotNull(OutputConfiguration(surface), preview?.let { PreviewRelay.outputConfiguration(it) }),
            ContextCompat.getMainExecutor(this),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(configured: CameraCaptureSession) {
                    if (!active) {
                        configured.close()
                        return
                    }
                    session = configured
                    try {
                        configured.setRepeatingRequest(request.build(), null, mainHandler)
                        // Only start the encoder once frames are flowing to its surface.
                        mediaRecorder.start()
                        recordingStarted = true
                        RecorderStateHolder.update(RecorderStatus.RECORDING)
                        Log.i(TAG, "Recording started")
                    } catch (e: CameraAccessException) {
                        fail("camera_unavailable", "Could not start the repeating request.", e)
                    } catch (e: RuntimeException) {
                        fail("recording_failed", "Could not start the recorder: ${e.message}", e)
                    }
                }

                override fun onConfigureFailed(failed: CameraCaptureSession) {
                    failed.close()
                    if (!active) return
                    if (preview != null) {
                        // Some devices cannot deliver a second stream next to the recording. The
                        // recording matters more than the preview, so go on without it.
                        Log.w(TAG, "The camera could not deliver a preview next to the recording")
                        dropPreview()
                        RecorderStateHolder.warn("preview_unavailable", "The camera cannot show a preview while recording.")
                        try {
                            startCaptureSession(device, withPreview = false)
                        } catch (e: CameraAccessException) {
                            fail("camera_unavailable", "Could not start the capture session.", e)
                        } catch (e: RuntimeException) {
                            fail("recording_failed", "Could not start the capture session: ${e.message}", e)
                        }
                    } else {
                        fail("recording_failed", "The camera could not be configured for recording.")
                    }
                }
            },
        )
        device.createCaptureSession(configuration)
    }

    /**
     * Stops the recorder and releases every resource. With [save] the output is published when the
     * recorder produced valid data; otherwise it is deleted. Safe to call when not [active].
     */
    private fun finishRecording(save: Boolean): RecordedMedia? {
        if (!active) return null
        active = false

        stopWatchingThermalStatus()
        dropPreview()
        val mediaRecorder = recorder
        val destination = output
        val started = recordingStarted
        recorder = null
        output = null
        recordingStarted = false

        var stoppedCleanly = false
        if (mediaRecorder != null && started) {
            try {
                session?.stopRepeating()
                session?.abortCaptures()
            } catch (_: CameraAccessException) {
            } catch (_: IllegalStateException) {
            }
            try {
                mediaRecorder.stop()
                stoppedCleanly = true
            } catch (e: RuntimeException) {
                // Thrown when no valid data was received (e.g. stopped immediately after start).
                Log.w(TAG, "MediaRecorder.stop() failed", e)
            }
        }
        session?.close()
        session = null
        camera?.close()
        camera = null
        captureRequest = null
        mediaRecorder?.release()

        if (destination == null) return null
        return try {
            if (save && stoppedCleanly) {
                destination.finish().copy(hasLocation = locationEmbedded)
            } else {
                destination.discard()
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Could not finalize the video", e)
            destination.discard()
            null
        }
    }

    /**
     * Ends the recording because of a failure. With [save] the video recorded so far is kept. When a
     * recording was in progress the user is told through a notification, since the app may not be
     * on screen and the foreground notification is removed.
     */
    private fun fail(code: String, message: String, cause: Throwable? = null, save: Boolean = false) {
        Log.e(TAG, "$code: $message", cause)
        val wasRecording = recordingStarted
        val video = finishRecording(save)
        RecorderStateHolder.update(RecorderStatus.ERROR, code, message, video)
        if (wasRecording) RecorderNotifications.postFailureAlert(this, code, saved = video != null)
        shutdown()
    }

    /** Stops feeding the on-screen preview. The preview shows nothing from here on. */
    private fun dropPreview() {
        val surface = previewSurface ?: return
        previewSurface = null
        PreviewRelay.releaseInputSurface(only = surface)
    }

    private fun availableStorageBytes(): Long {
        val directory = getExternalFilesDir(null) ?: return Long.MAX_VALUE
        return StatFs(directory.path).availableBytes
    }

    private fun watchThermalStatus() {
        thermalWarned = false
        val power = getSystemService(PowerManager::class.java)
        val listener = PowerManager.OnThermalStatusChangedListener { status ->
            when {
                !active -> Unit
                status >= PowerManager.THERMAL_STATUS_CRITICAL ->
                    fail("thermal_shutdown", "The device is overheating.", save = recordingStarted)
                status >= PowerManager.THERMAL_STATUS_SEVERE && !thermalWarned -> {
                    thermalWarned = true
                    RecorderStateHolder.warn("thermal_warning", "The device is getting hot and may stop the recording.")
                }
            }
        }
        thermalListener = listener
        power.addThermalStatusListener(ContextCompat.getMainExecutor(this), listener)
    }

    private fun stopWatchingThermalStatus() {
        thermalListener?.let { getSystemService(PowerManager::class.java).removeThermalStatusListener(it) }
        thermalListener = null
    }

    private fun shutdown() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun isGranted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    // endregion

    companion object {
        private const val TAG = "BackgroundVideoRecorder"
        private const val AUDIO_SAMPLE_RATE = 48_000
        private const val AUDIO_BIT_RATE = 128_000

        /** Refuse to start with less free space than this. */
        private const val MIN_FREE_BYTES = 100L * 1024 * 1024

        /** Below this much free space a recorder error is treated as the disk being full. */
        private const val LOW_STORAGE_BYTES = 16L * 1024 * 1024

        /** Space left free when the recorder is capped, so that other apps and the system keep working. */
        private const val STORAGE_MARGIN_BYTES = 50L * 1024 * 1024

        internal const val ACTION_START = "com.lightsoftware.flutter_background_video_recorder.START"
        internal const val ACTION_STOP = "com.lightsoftware.flutter_background_video_recorder.STOP"

        /** The running service, if any. Only touch it from the main thread. */
        @Volatile
        internal var instance: VideoRecorderService? = null
            private set
    }
}
