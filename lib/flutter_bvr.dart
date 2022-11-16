
import 'flutter_bvr_platform_interface.dart';

class FlutterBackgroundVideoRecorder {
  Future<bool?> startVideoRecording() {
    return FlutterBackgroundVideoRecorderPlatform.instance.startVideoRecording();
  }

  Future<String?> stopVideoRecording() {
    return FlutterBackgroundVideoRecorderPlatform.instance.stopVideoRecording();
  }

  Stream<int> get recorderState {
    return FlutterBackgroundVideoRecorderPlatform.instance.recorderState;
  }

  Future<int?> getVideoRecordingStatus() {
    return FlutterBackgroundVideoRecorderPlatform.instance.getVideoRecordingStatus();
  }
}
