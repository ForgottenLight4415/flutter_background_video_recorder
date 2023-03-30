import 'package:flutter/services.dart';

import 'flutter_bvr_platform_interface.dart';

/// An implementation of [FlutterBackgroundVideoRecorderPlatform] that uses method channels.
class FlutterBVRChannel extends FlutterBackgroundVideoRecorderPlatform {
  /// The method channel used to interact with the native platform.
  static const MethodChannel _methodChannel =
      MethodChannel('flutter_background_video_recorder');

  /// The event channel used to interact with the native platform.
  static const EventChannel _eventChannel =
      EventChannel('flutter_background_video_recorder_event');

  /// Method used to get the most recent status of the video recorder
  @override
  Future<int> getRecordingStatus() async {
    return await _methodChannel.invokeMethod<int>("getRecordingStatus") ?? -1;
  }

  /// Stream that transmits the current status of video recorder from
  /// native platform to event channel
  @override
  Stream<int> get recorderState {
    return _eventChannel.receiveBroadcastStream().map((value) => value as int);
  }

  /// Method to start recording video
  @override
  Future<bool?> startVideoRecording(
      {required String folderName,
      required CameraFacing cameraFacing,
      required String notificationTitle,
      required String notificationText,
      required bool showToast}) async {
    return await _methodChannel.invokeMethod<bool?>(
      "startVideoRecording",
      {
        "videoFolderName": folderName,
        "cameraFacing": cameraFacing == CameraFacing.frontCamera
            ? "Front Camera"
            : "Rear Camera",
        "notificationTitle": notificationTitle,
        "notificationText": notificationText,
        "showToast": showToast ? 'true' : 'false'
      },
    );
  }

  @override
  Future<String?> stopVideoRecording() async {
    return await _methodChannel.invokeMethod<String?>("stopVideoRecording");
  }
}
