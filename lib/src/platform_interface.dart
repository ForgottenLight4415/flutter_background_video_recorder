import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel.dart';
import 'models.dart';

/// The interface that platform implementations of flutter_background_video_recorder must extend.
abstract class FlutterBackgroundVideoRecorderPlatform
    extends PlatformInterface {
  /// Constructs a FlutterBackgroundVideoRecorderPlatform.
  FlutterBackgroundVideoRecorderPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterBackgroundVideoRecorderPlatform _instance =
      MethodChannelFlutterBackgroundVideoRecorder();

  /// The default instance of [FlutterBackgroundVideoRecorderPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterBackgroundVideoRecorder].
  static FlutterBackgroundVideoRecorderPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterBackgroundVideoRecorderPlatform] when
  /// they register themselves.
  static set instance(FlutterBackgroundVideoRecorderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns the current state of the recorder.
  Future<RecorderStatus> getRecordingStatus() {
    throw UnimplementedError('getRecordingStatus() has not been implemented.');
  }

  /// Stream of state changes reported by the recorder.
  Stream<RecorderEvent> get recorderEvents {
    throw UnimplementedError('recorderEvents has not been implemented.');
  }

  /// The cameras of the device.
  Future<List<CameraInfo>> listCameras() {
    throw UnimplementedError('listCameras() has not been implemented.');
  }

  /// The sizes, frame rates and codecs the chosen camera can record. A [cameraId] from
  /// [listCameras] takes precedence over [cameraFacing].
  Future<VideoCapabilities> getVideoCapabilities(
    CameraFacing cameraFacing, {
    String? cameraId,
  }) {
    throw UnimplementedError(
      'getVideoCapabilities() has not been implemented.',
    );
  }

  /// Sets the zoom ratio of the open camera and returns the ratio that was applied.
  ///
  /// Throws [RecorderErrorCode.cameraNotActive] if no camera is open.
  Future<double> setZoom(double ratio) {
    throw UnimplementedError('setZoom() has not been implemented.');
  }

  /// Requests permissions if needed and starts the recording service.
  ///
  /// Throws a [RecorderException] if recording cannot be started.
  Future<StartRecordingResult> startVideoRecording({
    required String folderName,
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    VideoSettings settings = const VideoSettings(),
  }) {
    throw UnimplementedError('startVideoRecording() has not been implemented.');
  }

  /// Records sound only. Needs the microphone permission but not the camera.
  Future<StartRecordingResult> startAudioRecording({
    required String folderName,
    required String notificationTitle,
    required String notificationText,
  }) {
    throw UnimplementedError('startAudioRecording() has not been implemented.');
  }

  /// Stops the recording, saves it and stops the service.
  ///
  /// Throws a [RecorderException] if nothing is being recorded or the recording could not be saved.
  Future<RecordedMedia> stopRecording() {
    throw UnimplementedError('stopRecording() has not been implemented.');
  }

  /// Starts a preview of the camera picture and returns where to find it. See [RecorderPreview].
  Future<PreviewInfo> startPreview({
    required CameraFacing cameraFacing,
    String? cameraId,
    VideoResolution? resolution,
    bool mirrorFront = true,
    double initialZoom = 1.0,
  }) {
    throw UnimplementedError('startPreview() has not been implemented.');
  }

  /// Ends the preview with the given texture. The recording, if any, is not affected.
  Future<void> stopPreview(int textureId) {
    throw UnimplementedError('stopPreview() has not been implemented.');
  }

  /// Opens the camera for a frame session. See [FlutterBackgroundVideoRecorder.openFrameSession].
  Future<RawFrameSessionInfo> openFrameSession({
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    RawFrameSettings settings = const RawFrameSettings(),
  }) {
    throw UnimplementedError('openFrameSession() has not been implemented.');
  }

  /// Closes the frame session, if one is open.
  Future<void> closeFrameSession() {
    throw UnimplementedError('closeFrameSession() has not been implemented.');
  }

  /// The frames of the open frame session. A broadcast stream: the native side only prepares
  /// frames while it has a listener. Completes for each listener when the session closes.
  Stream<RawFrame> get rawFrames {
    throw UnimplementedError('rawFrames has not been implemented.');
  }

  /// Opens the microphone for an audio stream. See
  /// [FlutterBackgroundVideoRecorder.openAudioStream].
  Future<RawAudioSessionInfo> openAudioStream({
    required String notificationTitle,
    required String notificationText,
    RawAudioSettings settings = const RawAudioSettings(),
  }) {
    throw UnimplementedError('openAudioStream() has not been implemented.');
  }

  /// Closes the audio stream, if one is open.
  Future<void> closeAudioStream() {
    throw UnimplementedError('closeAudioStream() has not been implemented.');
  }

  /// The sound of the open audio stream. A broadcast stream, like [rawFrames].
  Stream<RawAudioChunk> get rawAudio {
    throw UnimplementedError('rawAudio has not been implemented.');
  }

  /// Opens the app's page in the system settings. Returns false if it could not be opened.
  Future<bool> openAppSettings() {
    throw UnimplementedError('openAppSettings() has not been implemented.');
  }
}
