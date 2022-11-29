import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_bvr_channel.dart';

abstract class FlutterBackgroundVideoRecorderPlatform
    extends PlatformInterface {
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

  // Get current state of video recorder
  // Use to query the state for the first time after starting the service
  // Once service starts, recording events can be called using [recorderState] getter
  // * States are denoted by integer numbers
  //    - -1: Recorder service not initialized
  //    - 1: Recording has started
  //    - 2: Recording has stopped
  //    - 3: Recorder is being initialized and about to start recording
  //    - 4: An exception has occurred in the recording service
  Future<int?> getVideoRecordingStatus() {
    throw UnimplementedError(
        'getVideoRecordingStatus() has not been implemented.');
  }

  ///  * Gets a stream of video recorder states.
  ///  * Useful to query the state when updating the UI based on the state.
  ///  * States are denoted by integer numbers
  ///    - 1: Recording has started
  ///    - 2: Recording has stopped
  ///    - 3: Recorder is being initialized and about to start recording
  ///    - 4: An exception has occurred in the recording service
  Stream<int> get recorderState {
    throw UnimplementedError('recorderState has not been implemented.');
  }

  // Starts service and records video
  Future<bool?> startVideoRecording() {
    throw UnimplementedError('startVideoRecording() has not been implemented.');
  }

  // Stops recording video and releases the service
  Future<String?> stopVideoRecording() {
    throw UnimplementedError('stopVideoRecording() has not been implemented.');
  }
}
