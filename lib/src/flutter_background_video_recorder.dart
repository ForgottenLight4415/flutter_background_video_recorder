import 'models.dart';
import 'platform_interface.dart';

/// Records video with the camera and microphone from an Android foreground service, so recording
/// continues when the app is in the background or the screen is off.
///
/// Recording must be started while the app is visible: Android does not let apps in the
/// background open the camera or microphone.
class FlutterBackgroundVideoRecorder {
  /// Creates a recorder. All instances share the one recorder of the device.
  const FlutterBackgroundVideoRecorder();

  FlutterBackgroundVideoRecorderPlatform get _platform =>
      FlutterBackgroundVideoRecorderPlatform.instance;

  /// The sizes, frame rates and codecs the camera facing [cameraFacing] can record on this device.
  ///
  /// Use it to build pickers, and to check that a [VideoSettings] is supported before starting.
  /// Throws [RecorderErrorCode.cameraNotFound] if the device has no such camera.
  Future<VideoCapabilities> getVideoCapabilities(CameraFacing cameraFacing) =>
      _platform.getVideoCapabilities(cameraFacing);

  /// Starts recording a video into `Movies/[folderName]`.
  ///
  /// Asks for the camera, microphone and (Android 13+) notification permissions first when they
  /// are missing. Returns [StartRecordingResult.started] once the service is running; listen to
  /// [recorderState] to know when recording has actually begun. [notificationTitle] and
  /// [notificationText] are shown in the notification Android requires while recording.
  ///
  /// [settings] chooses the size, frame rate, codec and bitrate; the default is 1080p at 60 fps
  /// with H.264.
  ///
  /// Throws a [RecorderException] when recording cannot be started, for example
  /// [RecorderErrorCode.alreadyRecording] or [RecorderErrorCode.unsupportedConfiguration].
  Future<StartRecordingResult> startVideoRecording({
    required String folderName,
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    VideoSettings settings = const VideoSettings(),
  }) {
    return _platform.startVideoRecording(
      folderName: folderName,
      cameraFacing: cameraFacing,
      notificationTitle: notificationTitle,
      notificationText: notificationText,
      settings: settings,
    );
  }

  /// Records sound only, into `Recordings/[folderName]`.
  ///
  /// Only the microphone permission is needed (not the camera one), and Android shows only the
  /// microphone indicator. Everything else works as in [startVideoRecording], including
  /// [recorderState], [recorderErrors] and [stopRecording].
  Future<StartRecordingResult> startAudioRecording({
    required String folderName,
    required String notificationTitle,
    required String notificationText,
  }) {
    return _platform.startAudioRecording(
      folderName: folderName,
      notificationTitle: notificationTitle,
      notificationText: notificationText,
    );
  }

  /// Stops the recording (video or audio) and returns what was saved.
  ///
  /// Throws a [RecorderException] with [RecorderErrorCode.notRecording] if nothing is being
  /// recorded, or [RecorderErrorCode.stopFailed] if the recording contained no data.
  Future<RecordedMedia> stopRecording() => _platform.stopRecording();

  /// Same as [stopRecording].
  Future<RecordedMedia> stopVideoRecording() => stopRecording();

  /// Stream of recorder state changes.
  ///
  /// It does not emit the current state on listen; use [getRecordingStatus] for that.
  Stream<RecorderStatus> get recorderState => _platform.recorderEvents
      .where((event) => event.warning == null && event.preview == null)
      .map((event) => event.status);

  /// Stream of failures that happen after recording started, such as a lost camera. Each error
  /// is accompanied by a [RecorderStatus.error] on [recorderState].
  ///
  /// When the video recorded up to the failure could be saved, [RecorderException.savedMedia]
  /// points to it. Android also shows a notification so the user knows even if the app is closed.
  Stream<RecorderException> get recorderErrors => _platform.recorderEvents
      .where((event) => event.error != null)
      .map((event) => event.error!);

  /// Stream of problems that do not end the recording, for example
  /// [RecorderWarningCode.thermalWarning] when the device is getting hot.
  Stream<RecorderWarning> get recorderWarnings => _platform.recorderEvents
      .where((event) => event.warning != null)
      .map((event) => event.warning!);

  /// The current state of the recorder. Use it when the app starts to find out whether a
  /// recording is still running from an earlier session.
  Future<RecorderStatus> getRecordingStatus() => _platform.getRecordingStatus();

  /// Opens the app's page in the system settings.
  ///
  /// Use it when [startVideoRecording] returns [StartRecordingResult.permissionPermanentlyDenied]:
  /// Android no longer shows the permission dialog, so the user has to grant the camera and
  /// microphone permissions there. Returns false if the settings page could not be opened.
  Future<bool> openAppSettings() => _platform.openAppSettings();
}
