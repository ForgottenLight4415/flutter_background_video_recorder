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

  /// The cameras of this device, for example a main, an ultra-wide and a telephoto camera on the
  /// back and one on the front.
  ///
  /// Pass a [CameraInfo.id] as `cameraId` to [getVideoCapabilities], [startVideoRecording],
  /// [openFrameSession] or [RecorderPreview] to use that camera instead of the first one facing
  /// the chosen [CameraFacing].
  Future<List<CameraInfo>> listCameras() => _platform.listCameras();

  /// The sizes, frame rates and codecs a camera can record on this device: the camera with the
  /// id [cameraId] if given, otherwise the first camera facing [cameraFacing].
  ///
  /// Use it to build pickers, and to check that a [VideoSettings] is supported before starting.
  /// Throws [RecorderErrorCode.cameraNotFound] if the device has no such camera.
  Future<VideoCapabilities> getVideoCapabilities(
    CameraFacing cameraFacing, {
    String? cameraId,
  }) => _platform.getVideoCapabilities(cameraFacing, cameraId: cameraId);

  /// Zooms the open camera to [ratio] and returns the ratio that was applied, which is [ratio]
  /// limited to [CameraInfo.zoomRange].
  ///
  /// It works while recording, while a [RawFrameSession] is open and while a [RecorderPreview] is
  /// showing, and it zooms what the camera delivers: the recorded video, the preview and the raw
  /// frames. A new recording, preview or session starts at 1.0 unless you pass an `initialZoom`.
  ///
  /// Throws [RecorderErrorCode.cameraNotActive] when no camera is open.
  Future<double> setZoom(double ratio) => _platform.setZoom(ratio);

  /// Starts recording a video into `Movies/[folderName]`.
  ///
  /// Asks for the camera, microphone and (Android 13+) notification permissions first when they
  /// are missing. Returns [StartRecordingResult.started] once the service is running; listen to
  /// [recorderState] to know when recording has actually begun. [notificationTitle] and
  /// [notificationText] are shown in the notification Android requires while recording.
  ///
  /// [settings] chooses the size, frame rate, codec and bitrate; the default is 1080p at 60 fps
  /// with H.264. [cameraId] picks a camera from [listCameras]; it wins over [cameraFacing].
  ///
  /// Throws a [RecorderException] when recording cannot be started, for example
  /// [RecorderErrorCode.alreadyRecording] or [RecorderErrorCode.unsupportedConfiguration].
  Future<StartRecordingResult> startVideoRecording({
    required String folderName,
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    VideoSettings settings = const VideoSettings(),
  }) {
    return _platform.startVideoRecording(
      folderName: folderName,
      cameraFacing: cameraFacing,
      cameraId: cameraId,
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

  /// Opens a camera and delivers its frames to anyone who listens to [RawFrameSession.frames],
  /// until [RawFrameSession.close] is called.
  ///
  /// This is for apps that want the pictures themselves (to analyse, stream or encode them) and
  /// is independent of recording: no recording is started and nothing is saved. It runs from a
  /// foreground service, so it keeps going when the app is in the background, and like recording
  /// it must be started while the app is visible. Asks for the camera (and notification)
  /// permission when missing.
  ///
  /// The pixels of a [RawFrame] are shared native memory, not a copy, and a frame is only valid
  /// while the listeners of [RawFrameSession.frames] run. Call [RawFrame.retain] to keep one longer,
  /// or [RawFrame.toOwned] to copy it.
  ///
  /// **While developing, stop and restart the app instead of hot restarting it.** A session runs in
  /// a foreground service that outlives the Dart code: a hot restart discards the
  /// [RawFrameSession] you held but not the session, so opening one again fails with
  /// [RecorderErrorCode.cameraBusy] until the app is stopped and run again.
  ///
  /// The camera is exclusive: while a frame session is open, recording a video or showing a
  /// [RecorderPreview] fails with [RecorderErrorCode.cameraBusy], and so does opening a session
  /// while any of those is running. [cameraId] picks a camera from [listCameras]; it wins over
  /// [cameraFacing]. [settings] chooses the pixel format, size and rate.
  ///
  /// Throws a [RecorderException], for example [RecorderErrorCode.permissionDenied],
  /// [RecorderErrorCode.permissionPermanentlyDenied] or [RecorderErrorCode.cameraBusy].
  Future<RawFrameSession> openFrameSession({
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    RawFrameSettings settings = const RawFrameSettings(),
  }) async {
    final info = await _platform.openFrameSession(
      cameraFacing: cameraFacing,
      cameraId: cameraId,
      notificationTitle: notificationTitle,
      notificationText: notificationText,
      settings: settings,
    );
    return RawFrameSession(
      info: info,
      frames: _platform.rawFrames,
      onClose: _platform.closeFrameSession,
    );
  }

  /// Opens the microphone and delivers its sound as raw samples to anyone who listens to
  /// [RawAudioSession.chunks], until [RawAudioSession.close] is called.
  ///
  /// Independent of recording and of [openFrameSession]; both can run at once. It runs from a
  /// foreground service, so it keeps going in the background, and must be started while the app
  /// is visible. Asks for the microphone (and notification) permission when missing.
  ///
  /// **While developing, stop and restart the app instead of hot restarting it**, for the reason
  /// explained at [openFrameSession]: the stream keeps running natively, and opening it again fails
  /// with [RecorderErrorCode.microphoneBusy].
  ///
  /// The microphone is exclusive: while an audio stream is open, [startVideoRecording] and
  /// [startAudioRecording] fail with [RecorderErrorCode.microphoneBusy], and so does opening a
  /// stream while one of them is running.
  ///
  /// Throws a [RecorderException], for example [RecorderErrorCode.permissionDenied] or
  /// [RecorderErrorCode.unsupportedConfiguration].
  Future<RawAudioSession> openAudioStream({
    required String notificationTitle,
    required String notificationText,
    RawAudioSettings settings = const RawAudioSettings(),
  }) async {
    final info = await _platform.openAudioStream(
      notificationTitle: notificationTitle,
      notificationText: notificationText,
      settings: settings,
    );
    return RawAudioSession(
      info: info,
      chunks: _platform.rawAudio,
      onClose: _platform.closeAudioStream,
    );
  }

  /// Opens the app's page in the system settings.
  ///
  /// Use it when [startVideoRecording] returns [StartRecordingResult.permissionPermanentlyDenied]:
  /// Android no longer shows the permission dialog, so the user has to grant the camera and
  /// microphone permissions there. Returns false if the settings page could not be opened.
  Future<bool> openAppSettings() => _platform.openAppSettings();
}
