import 'recording.dart';

/// Reasons a recorder operation can fail.
enum RecorderErrorCode {
  /// The arguments of a call were missing or invalid.
  invalidArguments,

  /// A recording is already running or starting.
  alreadyRecording,

  /// There is no recording to stop.
  notRecording,

  /// A permission dialog is already on screen.
  permissionRequestInProgress,

  /// Permissions had to be asked for but the app has no activity on screen.
  noActivity,

  /// Android refused to start the recording service, because the app was not on screen.
  foregroundServiceNotAllowed,

  /// The recording service could not enter the foreground.
  foregroundServiceFailed,

  /// The recording contained no valid data and was discarded.
  stopFailed,

  /// A permission needed to record was not granted.
  permissionDenied,

  /// The device has no camera facing that way.
  cameraNotFound,

  /// The camera is disabled or in use by another app.
  cameraUnavailable,

  /// The camera was disconnected, for example taken by another app, while recording.
  cameraDisconnected,

  /// The camera reported an error while recording.
  cameraError,

  /// The output file could not be created.
  storageError,

  /// The device ran out of storage.
  storageFull,

  /// The device overheated and the recording was stopped to protect it.
  thermalShutdown,

  /// The requested [VideoSettings] are not supported by the camera.
  unsupportedConfiguration,

  /// [VideoSettings.embedLocation] needs a location permission in the app's manifest.
  locationPermissionNotDeclared,

  /// The recording failed for another reason. [RecorderException.message] has details.
  recordingFailed,

  /// The camera is already used by a recording, a preview or a frame session.
  ///
  /// While developing, this is also what you get after a **hot restart** with a raw session
  /// open: the Dart side starts afresh but the session keeps running. Stop the app and run it
  /// again (see "Things to know" in the README).
  cameraBusy,

  /// The microphone is already used by a recording or an audio stream. After a hot restart with an
  /// audio stream open this is the same development-time situation as [cameraBusy] describes.
  microphoneBusy,

  /// There is no open camera to zoom: start a recording, a preview or a frame session first.
  cameraNotActive,

  /// A permission was denied and Android no longer shows its dialog. Send the user to
  /// [FlutterBackgroundVideoRecorder.openAppSettings].
  permissionPermanentlyDenied,

  /// An error this version of the package does not know about.
  unknown;

  /// Maps the error code sent by the native side.
  static RecorderErrorCode fromWire(String? code) => switch (code) {
    'invalid_arguments' => invalidArguments,
    'already_recording' => alreadyRecording,
    'not_recording' => notRecording,
    'permission_request_in_progress' => permissionRequestInProgress,
    'no_activity' => noActivity,
    'foreground_service_not_allowed' => foregroundServiceNotAllowed,
    'foreground_service_failed' => foregroundServiceFailed,
    'stop_failed' => stopFailed,
    'permission_denied' => permissionDenied,
    'camera_not_found' => cameraNotFound,
    'camera_unavailable' => cameraUnavailable,
    'camera_disconnected' => cameraDisconnected,
    'camera_error' => cameraError,
    'storage_error' => storageError,
    'storage_full' => storageFull,
    'thermal_shutdown' => thermalShutdown,
    'unsupported_configuration' => unsupportedConfiguration,
    'location_permission_not_declared' => locationPermissionNotDeclared,
    'recording_failed' => recordingFailed,
    'camera_busy' => cameraBusy,
    'microphone_busy' => microphoneBusy,
    'camera_not_active' => cameraNotActive,
    'permission_permanently_denied' => permissionPermanentlyDenied,
    _ => unknown,
  };
}

/// Thrown by recorder operations, and emitted by
/// [FlutterBackgroundVideoRecorder.recorderErrors] for failures that happen while recording.
class RecorderException implements Exception {
  /// A failure with the given [code], an optional [message] and, if the recording was saved up to
  /// the failure, the [savedMedia].
  const RecorderException(this.code, [this.message, this.savedMedia]);

  /// What went wrong.
  final RecorderErrorCode code;

  /// A description for developers, when there is one.
  final String? message;

  /// Set when the recording failed midway (for example [RecorderErrorCode.cameraDisconnected])
  /// but the video recorded up to that point was saved.
  final RecordedMedia? savedMedia;

  @override
  String toString() =>
      'RecorderException(${code.name}${message == null ? '' : ': $message'})';
}

/// Something that went wrong but did not end the recording.
enum RecorderWarningCode {
  /// The device is getting hot. Android may stop the recording if it keeps heating up.
  thermalWarning,

  /// The recording started without a live preview because the camera could not deliver one next to
  /// the recording.
  previewUnavailable,

  /// The app did not take the audio of an [RawAudioSession] fast enough, so some of it was
  /// dropped.
  audioOverrun,

  /// A warning this version of the package does not know about.
  unknown;

  /// Maps the warning code sent by the native side.
  static RecorderWarningCode fromWire(String? code) => switch (code) {
    'thermal_warning' => thermalWarning,
    'preview_unavailable' => previewUnavailable,
    'audio_overrun' => audioOverrun,
    _ => unknown,
  };
}

/// A problem reported while recording that does not stop the recording.
class RecorderWarning {
  /// A warning with the given [code] and an optional [message].
  const RecorderWarning(this.code, [this.message]);

  /// What the warning is about.
  final RecorderWarningCode code;

  /// A description for developers, when there is one.
  final String? message;

  @override
  String toString() =>
      'RecorderWarning(${code.name}${message == null ? '' : ': $message'})';
}
