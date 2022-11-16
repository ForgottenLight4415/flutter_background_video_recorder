import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_bvr_channel.dart';

abstract class FlutterBackgroundVideoRecorderPlatform extends PlatformInterface {
  /// Constructs a FlutterBackgroundVideoRecorderPlatform.
  FlutterBackgroundVideoRecorderPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterBackgroundVideoRecorderPlatform _instance = FlutterBVRChannel();

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

  Future<int?> getVideoRecordingStatus() {
    throw UnimplementedError('getVideoRecordingStatus() has not been implemented.');
  }

  Stream<int> get recorderState {
    throw UnimplementedError('recorderState has not been implemented.');
  }

  Future<bool?> startVideoRecording() {
    throw UnimplementedError('startVideoRecording() has not been implemented.');
  }

  Future<String?> stopVideoRecording() {
    throw UnimplementedError('stopVideoRecording() has not been implemented.');
  }
}
