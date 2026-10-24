package com.lightsoftware.flutter_background_video_recorder.plugin

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Flutter plugin that records video with the camera and microphone from a foreground service. */
class FlutterBackgroundVideoRecorderPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    EventChannel.StreamHandler {

    private class StartRequest(
        val config: RecordingConfig,
        val embedLocation: Boolean,
        val result: MethodChannel.Result,
    )

    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var previews: PreviewManager

    private var eventSink: EventChannel.EventSink? = null
    private var eventListener: RecorderStateListener? = null

    /** A preview waiting for the camera permission dialog. */
    private class PendingPreview(val call: MethodCall, val result: MethodChannel.Result)

    private var pendingPreview: PendingPreview? = null

    private var activityBinding: ActivityPluginBinding? = null
    private var pendingStart: StartRequest? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also { it.setStreamHandler(this) }
        previews = PreviewManager(appContext, binding.textureRegistry) { event -> eventSink?.success(event) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        previews.dispose()
        onCancel(null)
    }

    // region Method channel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getRecordingStatus" -> result.success(RecorderStateHolder.status.wire)
            "getVideoCapabilities" -> getVideoCapabilities(call, result)
            "startVideoRecording" -> startVideoRecording(call, result)
            "startAudioRecording" -> startAudioRecording(call, result)
            "stopRecording", "stopVideoRecording" -> stopRecording(result)
            "openAppSettings" -> openAppSettings(result)
            "startPreview" -> startPreview(call, result)
            "stopPreview" -> {
                previews.stop((call.argument<Number>("textureId"))?.toLong() ?: -1L)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startVideoRecording(call: MethodCall, result: MethodChannel.Result) {
        val folderName = call.argument<String>("folderName")
        val cameraFacing = call.argument<String>("cameraFacing")
        val notificationTitle = call.argument<String>("notificationTitle")
        val notificationText = call.argument<String>("notificationText")
        if (folderName == null || notificationTitle == null || notificationText == null || !isValidFacing(cameraFacing)) {
            result.error("invalid_arguments", "Missing or invalid arguments for startVideoRecording.", null)
            return
        }
        if (!canStart(result)) return

        // Resolve the video settings now, before asking for permissions, so that a setting this
        // camera cannot do fails immediately.
        val frontFacing = cameraFacing == FACING_FRONT
        val capabilities = CameraCapabilitiesProvider.query(appContext, frontFacing)
        if (capabilities == null) {
            result.error("camera_not_found", "No ${if (frontFacing) "front" else "rear"} camera available.", null)
            return
        }
        val video = try {
            chooseVideoConfig(
                request = VideoRequest(
                    width = call.argument<Int>("width"),
                    height = call.argument<Int>("height"),
                    frameRate = call.argument<Int>("frameRate"),
                    codec = VideoCodec.fromWire(call.argument<String>("codec")),
                    bitrate = call.argument<Int>("bitrate"),
                ),
                modes = capabilities.modes,
                codecs = capabilities.codecs,
                referenceBitrate = { CameraCapabilitiesProvider.referenceBitrate(capabilities.cameraId, it) },
                codecMaxFps = { codec, size -> CameraCapabilitiesProvider.maxEncoderFps(codec, size) },
            )
        } catch (e: UnsupportedConfigurationException) {
            result.error("unsupported_configuration", e.message, null)
            return
        }

        val embedLocation = call.argument<Boolean>("embedLocation") == true
        if (embedLocation && declaredLocationPermissions().isEmpty()) {
            result.error(
                "location_permission_not_declared",
                "embedLocation needs ACCESS_FINE_LOCATION or ACCESS_COARSE_LOCATION in the app's AndroidManifest.xml.",
                null,
            )
            return
        }
        beginStart(
            StartRequest(
                RecordingConfig(
                    RecordingMode.VIDEO,
                    folderName,
                    frontFacing,
                    video,
                    notificationTitle,
                    notificationText,
                    preview = call.argument<Boolean>("preview") == true,
                ),
                embedLocation,
                result,
            ),
        )
    }

    /** Records sound only: no camera, no camera permission, and no camera privacy indicator. */
    private fun startAudioRecording(call: MethodCall, result: MethodChannel.Result) {
        val folderName = call.argument<String>("folderName")
        val notificationTitle = call.argument<String>("notificationTitle")
        val notificationText = call.argument<String>("notificationText")
        if (folderName == null || notificationTitle == null || notificationText == null) {
            result.error("invalid_arguments", "Missing or invalid arguments for startAudioRecording.", null)
            return
        }
        if (!canStart(result)) return
        beginStart(
            StartRequest(
                RecordingConfig(RecordingMode.AUDIO, folderName, false, null, notificationTitle, notificationText),
                embedLocation = false,
                result,
            ),
        )
    }

    /** Rejects the start if a recording is running or a permission dialog is open. */
    private fun canStart(result: MethodChannel.Result): Boolean {
        val status = RecorderStateHolder.status
        if (status == RecorderStatus.RECORDING || status == RecorderStatus.INITIALIZING) {
            result.error("already_recording", "A recording is already in progress.", null)
            return false
        }
        if (pendingStart != null) {
            result.error("permission_request_in_progress", "A permission request is already in progress.", null)
            return false
        }
        return true
    }

    /** Asks for the missing permissions (if any) and then starts the service. */
    private fun beginStart(request: StartRequest) {
        val missing = permissionsToRequest(request.config.mode, request.embedLocation)
        if (missing.isEmpty()) {
            launchService(request)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            request.result.error("no_activity", "Permissions must be requested while the app is in the foreground.", null)
            return
        }
        pendingStart = request
        ActivityCompat.requestPermissions(activity, missing.toTypedArray(), REQUEST_CODE_PERMISSIONS)
    }

    /** The sizes, frame rates and codecs this device can record with the chosen camera. */
    private fun getVideoCapabilities(call: MethodCall, result: MethodChannel.Result) {
        val cameraFacing = call.argument<String>("cameraFacing")
        if (!isValidFacing(cameraFacing)) {
            result.error("invalid_arguments", "Missing or invalid camera facing.", null)
            return
        }
        val frontFacing = cameraFacing == FACING_FRONT
        val capabilities = CameraCapabilitiesProvider.query(appContext, frontFacing)
        if (capabilities == null) {
            result.error("camera_not_found", "No ${if (frontFacing) "front" else "rear"} camera available.", null)
            return
        }
        fun codecMap(support: CodecSupport) = mapOf("supported" to support.supported, "hardware" to support.hardware)
        // What a recording uses when the app sets nothing, so the app can show real values.
        val recommended = try {
            chooseVideoConfig(VideoRequest(), capabilities.modes, capabilities.codecs)
        } catch (_: UnsupportedConfigurationException) {
            null
        }
        result.success(
            mapOf(
                "recommended" to recommended?.let {
                    mapOf("width" to it.dimension.width, "height" to it.dimension.height, "frameRate" to it.frameRate)
                },
                "modes" to capabilities.modes.map {
                    mapOf("width" to it.dimension.width, "height" to it.dimension.height, "frameRates" to it.frameRates)
                },
                "codecs" to mapOf(
                    "h264" to codecMap(capabilities.codecs.h264),
                    "hevc" to codecMap(capabilities.codecs.hevc),
                ),
            ),
        )
    }

    private fun isValidFacing(value: String?) = value == FACING_FRONT || value == FACING_REAR

    private fun stopRecording(result: MethodChannel.Result) {
        val service = VideoRecorderService.instance
        if (service == null || RecorderStateHolder.status != RecorderStatus.RECORDING) {
            result.error("not_recording", "There is no recording in progress.", null)
            return
        }
        val video = service.stopRecording()
        if (video == null) {
            result.error("stop_failed", "The recording contained no valid data and was discarded.", null)
        } else {
            result.success(
                mapOf(
                    "uri" to video.uri,
                    "path" to video.path,
                    "kind" to video.kind.wire,
                    "hasLocation" to video.hasLocation,
                ),
            )
        }
    }

    /** Starts the on-screen preview. Needs the camera permission, which is asked for if missing. */
    private fun startPreview(call: MethodCall, result: MethodChannel.Result) {
        val cameraFacing = call.argument<String>("cameraFacing")
        if (!isValidFacing(cameraFacing)) {
            result.error("invalid_arguments", "Missing or invalid camera facing.", null)
            return
        }
        if (isGranted(Manifest.permission.CAMERA)) {
            runStartPreview(call, result)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("no_activity", "The camera permission can only be asked for while the app is in the foreground.", null)
            return
        }
        if (pendingPreview != null) {
            result.error("permission_request_in_progress", "A permission request is already in progress.", null)
            return
        }
        pendingPreview = PendingPreview(call, result)
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), REQUEST_CODE_PREVIEW_PERMISSION)
    }

    private fun runStartPreview(call: MethodCall, result: MethodChannel.Result) {
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val aspect = if (width != null && height != null && height > 0) width.toDouble() / height else null
        try {
            result.success(
                previews.start(
                    frontFacing = call.argument<String>("cameraFacing") == FACING_FRONT,
                    wantedAspect = aspect,
                    mirrorFront = call.argument<Boolean>("mirrorFront") ?: true,
                ),
            )
        } catch (e: PreviewManager.PreviewException) {
            result.error(e.code, e.message, null)
        }
    }

    /** Opens this app's page in the system settings, where blocked permissions can be granted. */
    private fun openAppSettings(result: MethodChannel.Result) {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", appContext.packageName, null))
        val activity = activityBinding?.activity
        try {
            if (activity != null) {
                activity.startActivity(intent)
            } else {
                appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun launchService(request: StartRequest) {
        // Mark the recorder busy right away: finding a position can take a few seconds.
        RecorderStateHolder.update(RecorderStatus.INITIALIZING)
        if (!request.embedLocation) {
            startService(request)
            return
        }
        LocationFetcher.fetch(appContext) { coordinates ->
            startService(StartRequest(request.config.copy(location = coordinates), request.embedLocation, request.result))
        }
    }

    private fun startService(request: StartRequest) {
        val intent = request.config.toIntent(appContext)
        try {
            ContextCompat.startForegroundService(appContext, intent)
            request.result.success(RESULT_STARTED)
        } catch (e: SecurityException) {
            RecorderStateHolder.update(RecorderStatus.STOPPED)
            request.result.error("foreground_service_not_allowed", e.message, null)
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+): the app is not in a state that
            // may start a foreground service, typically because it is in the background.
            RecorderStateHolder.update(RecorderStatus.STOPPED)
            request.result.error("foreground_service_not_allowed", e.message, null)
        }
    }

    // endregion

    // region Permissions

    /** Permissions without which recording cannot work. */
    private fun requiredPermissions(mode: RecordingMode): List<String> = when (mode) {
        RecordingMode.VIDEO -> listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        RecordingMode.AUDIO -> listOf(Manifest.permission.RECORD_AUDIO)
    }

    /** Required permissions plus, on Android 13+, the (optional) notification permission. */
    private fun permissionsToRequest(mode: RecordingMode, embedLocation: Boolean): List<String> {
        val wanted = requiredPermissions(mode).toMutableList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        // Location is optional like notifications: recording works without it, just without a position.
        if (embedLocation) wanted.addAll(declaredLocationPermissions())
        return wanted.filter { !isGranted(it) }
    }

    /** The location permissions the app declared in its own manifest (the plugin declares none). */
    private fun declaredLocationPermissions(): List<String> {
        val requested = try {
            val packages = appContext.packageManager
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packages.getPackageInfo(
                    appContext.packageName,
                    PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()),
                )
            } else {
                // The flags overload only exists from Android 13.
                @Suppress("DEPRECATION")
                packages.getPackageInfo(appContext.packageName, PackageManager.GET_PERMISSIONS)
            }
            info.requestedPermissions.orEmpty()
        } catch (_: PackageManager.NameNotFoundException) {
            emptyArray()
        }
        return listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            .filter { it in requested }
    }

    private fun isGranted(permission: String) =
        ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode == REQUEST_CODE_PREVIEW_PERMISSION) {
            val waiting = pendingPreview ?: return true
            pendingPreview = null
            if (isGranted(Manifest.permission.CAMERA)) {
                runStartPreview(waiting.call, waiting.result)
            } else {
                waiting.result.error("permission_denied", "The camera permission is needed for the preview.", null)
            }
            return true
        }
        if (requestCode != REQUEST_CODE_PERMISSIONS) return false
        val request = pendingStart ?: return true
        pendingStart = null

        // The notification permission is optional: the service runs without it, the user just
        // does not see the notification.
        val denied = requiredPermissions(request.config.mode).filter { !isGranted(it) }
        if (denied.isEmpty()) {
            launchService(request)
            return true
        }
        val activity = activityBinding?.activity
        val permanentlyDenied = activity != null &&
            denied.any { !ActivityCompat.shouldShowRequestPermissionRationale(activity, it) }
        request.result.success(if (permanentlyDenied) RESULT_PERMISSION_PERMANENTLY_DENIED else RESULT_PERMISSION_DENIED)
        return true
    }

    // endregion

    // region Event channel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        val listener = object : RecorderStateListener {
            override fun onStateChanged(
                status: RecorderStatus,
                errorCode: String?,
                errorMessage: String?,
                video: RecordedMedia?,
            ) {
                events.success(
                    mapOf(
                        "type" to "state",
                        "status" to status.wire,
                        "errorCode" to errorCode,
                        "errorMessage" to errorMessage,
                        "mediaUri" to video?.uri,
                        "mediaPath" to video?.path,
                        "mediaKind" to video?.kind?.wire,
                        "mediaHasLocation" to video?.hasLocation,
                    ),
                )
            }

            override fun onWarning(code: String, message: String) {
                events.success(mapOf("type" to "warning", "warningCode" to code, "warningMessage" to message))
            }
        }
        eventListener = listener
        RecorderStateHolder.addListener(listener)
    }

    override fun onCancel(arguments: Any?) {
        eventListener?.let { RecorderStateHolder.removeListener(it) }
        eventListener = null
        eventSink = null
    }

    // endregion

    // region ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach(failPending = false)

    override fun onDetachedFromActivity() = detach(failPending = true)

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    private fun detach(failPending: Boolean) {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        if (failPending) {
            // The activity is gone for good, so the permission dialog result will never arrive.
            pendingStart?.result?.error("no_activity", "The activity was destroyed before permissions were granted.", null)
            pendingStart = null
        }
    }

    // endregion

    private companion object {
        const val METHOD_CHANNEL = "flutter_background_video_recorder"
        const val EVENT_CHANNEL = "flutter_background_video_recorder_event"
        const val REQUEST_CODE_PERMISSIONS = 4415
        const val REQUEST_CODE_PREVIEW_PERMISSION = 4416

        const val FACING_FRONT = "front"
        const val FACING_REAR = "rear"

        const val RESULT_STARTED = "started"
        const val RESULT_PERMISSION_DENIED = "permissionDenied"
        const val RESULT_PERMISSION_PERMANENTLY_DENIED = "permissionPermanentlyDenied"
    }
}
