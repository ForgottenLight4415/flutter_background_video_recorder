import 'package:flutter/services.dart';

import 'flutter_bvr_platform_interface.dart';

/// An implementation of [FlutterBackgroundVideoRecorderPlatform] that uses method channels.
class FlutterBVRChannel extends FlutterBackgroundVideoRecorderPlatform {
  /// The method channel used to interact with the native platform.
  static const MethodChannel _methodChannel =
      MethodChannel('flutter_background_video_recorder');
  static const EventChannel _eventChannel =
      EventChannel('flutter_background_video_recorder_event');

  @override
  Future<int> getVideoRecordingStatus() async {
    return await _methodChannel.invokeMethod<int>("getRecordingStatus") ?? -1;
  }

  @override
  Stream<int> get recorderState {
    return _eventChannel.receiveBroadcastStream().map((value) => value as int);
  }

  @override
  Future<bool?> startVideoRecording(
      {required String folderName,
      required CameraFacing cameraFacing,
      required String notificationTitle,
      required String notificationText}) async {
    return await _methodChannel.invokeMethod<bool?>(
      "startVideoRecording",
      {
        "videoFolderName": folderName,
        "cameraFacing": cameraFacing == CameraFacing.frontCamera
            ? "Front Camera"
            : "Rear Camera",
        "notificationTitle": notificationTitle,
        "notificationText": notificationText
      },
    );
  }

  @override
  Future<String?> stopVideoRecording() async {
    return await _methodChannel.invokeMethod<String?>("stopVideoRecording");
  }
}
