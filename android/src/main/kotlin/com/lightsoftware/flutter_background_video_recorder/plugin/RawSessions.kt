package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Added to the "busy" errors that a session left over from before a hot restart causes. A hot
 * restart starts the Dart side afresh, but the foreground service of a session keeps running, so
 * the app finds the camera or microphone taken by a session it no longer has a handle on.
 */
internal const val HOT_RESTART_HINT =
    " If you restarted the app while developing (hot restart), stop the app and run it again: " +
        "a hot restart does not end a session that is still open."

/**
 * The raw frame session and raw audio stream of the plugin: validating the request, asking for the
 * permissions, starting the foreground service, and answering the app once the session is open.
 *
 * What the sessions deliver goes out through [frameStream] and [audioStream], the stream handlers of
 * their event channels. Recording itself is not handled here; it only has to be kept out of each
 * other's way (a frame session and a video recording cannot share the camera, an audio stream and
 * any recording cannot share the microphone).
 *
 * Main thread only.
 */
internal class RawSessions(
    private val context: Context,
    private val previews: PreviewManager,
    /** The foreground activity, which permission dialogs need; null while there is none. */
    private val activity: () -> Activity?,
    /** Whether a permission dialog of the recorder is open, so that two do not stack. */
    private val otherPermissionRequestPending: () -> Boolean,
) {
    /** A session waiting for its permission dialog. */
    private class PendingSession(
        val required: List<String>,
        val result: MethodChannel.Result,
        val onGranted: () -> Unit,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingSession: PendingSession? = null

    /** Delivers the frames of the open frame session to the app's event channel. */
    val frameStream = SessionStreamHandler(FrameSessionHolder.holder, ::frameToMap)

    /** Delivers the sound of the open audio stream to the app's event channel. */
    val audioStream = SessionStreamHandler(AudioSessionHolder.holder, ::audioToMap)

    /** True while a permission dialog of a session is open. */
    val hasPendingPermissionRequest: Boolean get() = pendingSession != null

    /** True while a recording or the viewfinder holds the camera. */
    fun cameraInUse(): Boolean =
        RecorderStateHolder.activeMode == RecordingMode.VIDEO || previews.holdsCamera

    /** Asks for the missing [required] permissions (and the notification one), then runs [onGranted]. */
    private fun withPermissions(required: List<String>, result: MethodChannel.Result, onGranted: () -> Unit) {
        val wanted = required.toMutableList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        val missing = wanted.filter { !isGranted(it) }
        if (missing.isEmpty()) {
            onGranted()
            return
        }
        val activity = activity()
        if (activity == null) {
            result.error("no_activity", "Permissions must be requested while the app is in the foreground.", null)
            return
        }
        if (pendingSession != null || otherPermissionRequestPending()) {
            result.error("permission_request_in_progress", "A permission request is already in progress.", null)
            return
        }
        pendingSession = PendingSession(required, result, onGranted)
        ActivityCompat.requestPermissions(activity, missing.toTypedArray(), REQUEST_CODE_SESSION_PERMISSIONS)
    }

    /** Starts a service for [holder] and answers [result] when it has opened, or has failed to. */
    private fun <T, I> launchSession(
        holder: SessionHolder<T, I>,
        result: MethodChannel.Result,
        intent: Intent,
        busyError: Pair<String, String>,
        stop: () -> Unit,
        describe: (I) -> Map<String, Any?>,
    ) {
        if (holder.isOpen) {
            result.error(busyError.first, busyError.second, null)
            return
        }
        val timeout = Runnable {
            stop()
            holder.failed("camera_unavailable", "The session did not open in time.")
        }
        holder.begin { outcome ->
            mainHandler.removeCallbacks(timeout)
            when (outcome) {
                is OpenResult.Opened -> result.success(describe(outcome.info))
                is OpenResult.Failed -> result.error(outcome.code, outcome.message, null)
            }
        }
        mainHandler.postDelayed(timeout, OPEN_TIMEOUT_MS)
        try {
            ContextCompat.startForegroundService(context, intent)
        } catch (e: SecurityException) {
            stop()
            holder.failed("foreground_service_not_allowed", e.message ?: "The service could not be started.")
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+): typically the app is in the background.
            stop()
            holder.failed("foreground_service_not_allowed", e.message ?: "The service could not be started.")
        }
    }

    fun openFrameSession(call: MethodCall, result: MethodChannel.Result) {
        val cameraFacing = call.argument<String>("cameraFacing")
        val title = call.argument<String>("notificationTitle")
        val text = call.argument<String>("notificationText")
        if (title == null || text == null || !isValidFacing(cameraFacing)) {
            result.error("invalid_arguments", "Missing or invalid arguments for openFrameSession.", null)
            return
        }
        if (FrameSessionHolder.holder.isOpen) {
            result.error("camera_busy", "A frame session is already open.$HOT_RESTART_HINT", null)
            return
        }
        if (cameraInUse()) {
            result.error("camera_busy", "The camera is already in use by a recording or a preview.", null)
            return
        }
        val choice = CameraChoice(call.argument<String>("cameraId"), cameraFacing == FACING_FRONT)
        val capabilities = CameraCapabilitiesProvider.query(context, choice)
        if (capabilities == null) {
            result.error("camera_not_found", choice.notFoundMessage(), null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val frame = RawFrameConfig.fromArguments((call.arguments as? Map<String, Any?>).orEmpty())
        val dimension = chooseFrameDimension(capabilities.frameSizes, frame.size)
        if (dimension == null) {
            result.error("unsupported_configuration", "The camera offers no frame size.", null)
            return
        }
        val config = FrameSessionConfig(
            CameraChoice(capabilities.cameraId, capabilities.frontFacing),
            dimension,
            frame.copy(initialZoom = capabilities.zoomRange.clamp(frame.initialZoom)),
            title,
            text,
        )
        withPermissions(listOf(Manifest.permission.CAMERA), result) {
            launchSession(
                holder = FrameSessionHolder.holder,
                result = result,
                intent = config.toIntent(context),
                busyError = "camera_busy" to "A frame session is already open.$HOT_RESTART_HINT",
                stop = ::closeFrameSession,
                describe = { info ->
                    mapOf(
                        "cameraId" to info.cameraId,
                        "width" to info.width,
                        "height" to info.height,
                        "format" to info.format.wire,
                    )
                },
            )
        }
    }

    /** Closes the frame session, whichever stage it is in. Safe to call when none is open. */
    fun closeFrameSession() {
        val holder = FrameSessionHolder.holder
        if (!holder.isOpen) return
        val service = FrameCaptureService.instance
        if (service != null) {
            service.closeSession()
        } else {
            // The service is not up yet: tell it to stop as soon as it is.
            holder.closeRequested = true
            holder.closed()
        }
    }

    fun openAudioStream(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("notificationTitle")
        val text = call.argument<String>("notificationText")
        if (title == null || text == null) {
            result.error("invalid_arguments", "Missing or invalid arguments for openAudioStream.", null)
            return
        }
        if (AudioSessionHolder.holder.isOpen) {
            result.error("microphone_busy", "An audio stream is already open.$HOT_RESTART_HINT", null)
            return
        }
        if (RecorderStateHolder.activeMode != null) {
            result.error("microphone_busy", "The microphone is already in use by a recording.", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val audio = RawAudioConfig.fromArguments((call.arguments as? Map<String, Any?>).orEmpty())
        audio.problem()?.let {
            result.error("unsupported_configuration", it, null)
            return
        }
        val config = AudioSessionConfig(audio, title, text)
        withPermissions(listOf(Manifest.permission.RECORD_AUDIO), result) {
            launchSession(
                holder = AudioSessionHolder.holder,
                result = result,
                intent = config.toIntent(context),
                busyError = "microphone_busy" to "An audio stream is already open.$HOT_RESTART_HINT",
                stop = ::closeAudioStream,
                describe = { info ->
                    mapOf(
                        "sampleRate" to info.sampleRate,
                        "channels" to info.channels,
                        "encoding" to info.encoding.wire,
                    )
                },
            )
        }
    }

    fun closeAudioStream() {
        val holder = AudioSessionHolder.holder
        if (!holder.isOpen) return
        val service = AudioCaptureService.instance
        if (service != null) {
            service.closeSession()
        } else {
            holder.closeRequested = true
            holder.closed()
        }
    }

    /**
     * Handles the result of the permission dialog of a session. Returns false when [requestCode] is
     * not the one this class asked with.
     */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE_SESSION_PERMISSIONS) return false
        val waiting = pendingSession ?: return true
        pendingSession = null
        val denied = waiting.required.filter { !isGranted(it) }
        if (denied.isEmpty()) {
            waiting.onGranted()
            return true
        }
        val current = activity()
        val permanentlyDenied = current != null &&
            denied.any { !ActivityCompat.shouldShowRequestPermissionRationale(current, it) }
        waiting.result.error(
            if (permanentlyDenied) "permission_permanently_denied" else "permission_denied",
            "The ${denied.joinToString { it.substringAfterLast('.').lowercase() }} permission is required.",
            null,
        )
        return true
    }

    /** The activity is gone for good, so the answer of a permission dialog will never arrive. */
    fun failPendingPermissionRequest() {
        pendingSession?.result?.error("no_activity", "The activity was destroyed before permissions were granted.", null)
        pendingSession = null
    }

    /** Closes both sessions. For when nothing is left to read them, because the engine went away. */
    fun closeAll() {
        closeFrameSession()
        closeAudioStream()
    }

    private fun isGranted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private companion object {
        const val REQUEST_CODE_SESSION_PERMISSIONS = 4417

        /** How long a session may take to open before it is given up on. */
        const val OPEN_TIMEOUT_MS = 10_000L
    }
}

/**
 * The description of a frame that goes over the channel. The pixels do not: they stay in the native
 * slot, which Dart reads in place. Dart takes its own reference on the slot here, and drops it
 * through `dart:ffi` when it is done.
 */
private fun frameToMap(frame: RawFrameData): Map<String, Any?> {
    frame.lease.retainForDart()
    return mapOf(
        "type" to "frame",
        "ring" to frame.lease.ring,
        "slot" to frame.lease.slot,
        "address" to frame.lease.address,
        "format" to frame.format.wire,
        "width" to frame.width,
        "height" to frame.height,
        "rotation" to frame.rotation,
        "timestampNs" to frame.timestampNs,
        "dropped" to frame.dropped,
        "planes" to frame.planes.map {
            mapOf(
                "offset" to it.offset,
                "length" to it.length,
                "bytesPerRow" to it.rowStride,
                "bytesPerPixel" to it.pixelStride,
            )
        },
    )
}

private fun audioToMap(audio: RawAudioData): Map<String, Any?> = mapOf(
    "type" to "chunk",
    "bytes" to audio.bytes,
    "sampleRate" to audio.sampleRate,
    "channels" to audio.channels,
    "encoding" to audio.encoding.wire,
    "timestampNs" to audio.timestampNs,
)
