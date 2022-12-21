import 'flutter_bvr_platform_interface.dart';

class FlutterBackgroundVideoRecorder {
  // Start recording service and record video
  Future<bool?> startVideoRecording(
      {required String folderName,
      required CameraFacing cameraFacing,
      required String notificationTitle,
      required String notificationText}) {
    return FlutterBackgroundVideoRecorderPlatform.instance.startVideoRecording(
        folderName: folderName,
        cameraFacing: cameraFacing,
        notificationTitle: notificationTitle,
        notificationText: notificationText);
  }

  // Stop video recording, release resources and stop service
  Future<String?> stopVideoRecording() {
    return FlutterBackgroundVideoRecorderPlatform.instance.stopVideoRecording();
  }

  /// Get current state of video recorder as a stream
  /// * States are denoted by integer numbers
  ///    - 1: Recording has started
  ///    - 2: Recording has stopped
  ///    - 3: Recorder is being initialized and about to start recording
  ///    - 4: An exception has occurred in the recording service
  Stream<int> get recorderState {
    return FlutterBackgroundVideoRecorderPlatform.instance.recorderState;
  }

  // Get current state of video recorder
  // Once service starts, recording events can be called using [recorderState] getter
  // * States are denoted by integer numbers
  //    - -1: Recorder service not initialized
  //    - 1: Recording has started
  //    - 2: Recording has stopped
  //    - 3: Recorder is being initialized and about to start recording
  //    - 4: An exception has occurred in the recording service
  Future<int?> getVideoRecordingStatus() {
    return FlutterBackgroundVideoRecorderPlatform.instance
        .getVideoRecordingStatus();
  }
}
