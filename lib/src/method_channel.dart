import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'platform_interface.dart';

/// The [FlutterBackgroundVideoRecorderPlatform] that talks to Android over a method channel and
/// an event channel.
class MethodChannelFlutterBackgroundVideoRecorder
    extends FlutterBackgroundVideoRecorderPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel(
    'flutter_background_video_recorder',
  );

  /// The event channel used to receive recorder state changes from the native platform.
  @visibleForTesting
  static const EventChannel eventChannel = EventChannel(
    'flutter_background_video_recorder_event',
  );

  // Created once so that every listener shares a single native subscription.
  late final Stream<RecorderEvent> _events = eventChannel
      .receiveBroadcastStream()
      .map(_parseEvent);

  @override
  Future<RecorderStatus> getRecordingStatus() async {
    final status = await _invoke<String>('getRecordingStatus');
    return _parseStatus(status);
  }

  @override
  Stream<RecorderEvent> get recorderEvents => _events;

  static String _facing(CameraFacing facing) => switch (facing) {
    CameraFacing.frontCamera => 'front',
    CameraFacing.rearCamera => 'rear',
  };

  @override
  Future<VideoCapabilities> getVideoCapabilities(
    CameraFacing cameraFacing,
  ) async {
    final result = await _invoke<Map<Object?, Object?>>(
      'getVideoCapabilities',
      {'cameraFacing': _facing(cameraFacing)},
    );
    if (result == null) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The recorder did not report any capabilities.',
      );
    }
    CodecSupport codec(Object? raw) {
      final map = (raw as Map<Object?, Object?>?) ?? const {};
      return CodecSupport(
        supported: map['supported'] == true,
        hardwareAccelerated: map['hardware'] == true,
      );
    }

    final codecs = (result['codecs'] as Map<Object?, Object?>?) ?? const {};
    final recommended = result['recommended'] as Map<Object?, Object?>?;
    return VideoCapabilities(
      defaultResolution:
          recommended == null
              ? null
              : VideoResolution(
                recommended['width'] as int,
                recommended['height'] as int,
              ),
      defaultFrameRate: recommended?['frameRate'] as int?,
      modes: [
        for (final raw in (result['modes'] as List<Object?>? ?? const []))
          VideoMode(
            VideoResolution(
              (raw as Map<Object?, Object?>)['width'] as int,
              raw['height'] as int,
            ),
            List<int>.from(raw['frameRates'] as List<Object?>),
          ),
      ],
      h264: codec(codecs['h264']),
      hevc: codec(codecs['hevc']),
    );
  }

  @override
  Future<StartRecordingResult> startVideoRecording({
    required String folderName,
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    VideoSettings settings = const VideoSettings(),
  }) async {
    final result = await _invoke<String>('startVideoRecording', {
      'folderName': folderName,
      'cameraFacing': _facing(cameraFacing),
      'notificationTitle': notificationTitle,
      'notificationText': notificationText,
      if (settings.resolution != null) ...{
        'width': settings.resolution!.width,
        'height': settings.resolution!.height,
      },
      if (settings.frameRate != null) 'frameRate': settings.frameRate,
      'codec': settings.codec.name,
      if (settings.bitrate != null) 'bitrate': settings.bitrate,
      if (settings.embedLocation) 'embedLocation': true,
      if (settings.preview) 'preview': true,
    });
    return _parseStartResult(result);
  }

  @override
  Future<StartRecordingResult> startAudioRecording({
    required String folderName,
    required String notificationTitle,
    required String notificationText,
  }) async {
    final result = await _invoke<String>('startAudioRecording', {
      'folderName': folderName,
      'notificationTitle': notificationTitle,
      'notificationText': notificationText,
    });
    return _parseStartResult(result);
  }

  static StartRecordingResult _parseStartResult(String? result) =>
      switch (result) {
        'started' => StartRecordingResult.started,
        'permissionDenied' => StartRecordingResult.permissionDenied,
        'permissionPermanentlyDenied' =>
          StartRecordingResult.permissionPermanentlyDenied,
        _ =>
          throw RecorderException(
            RecorderErrorCode.unknown,
            'Unexpected start result: $result',
          ),
      };

  static RecordedMediaKind _parseKind(Object? kind) =>
      kind == 'audio' ? RecordedMediaKind.audio : RecordedMediaKind.video;

  @override
  Future<RecordedMedia> stopRecording() async {
    final result = await _invoke<Map<Object?, Object?>>('stopRecording');
    final uri = result?['uri'] as String?;
    if (uri == null) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The recorder did not return a recording.',
      );
    }
    return RecordedMedia(
      uri: uri,
      path: result?['path'] as String?,
      kind: _parseKind(result?['kind']),
      hasLocation: result?['hasLocation'] == true,
    );
  }

  @override
  Future<PreviewInfo> startPreview({
    required CameraFacing cameraFacing,
    VideoResolution? resolution,
    bool mirrorFront = true,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('startPreview', {
      'cameraFacing': _facing(cameraFacing),
      if (resolution != null) ...{
        'width': resolution.width,
        'height': resolution.height,
      },
      'mirrorFront': mirrorFront,
    });
    if (result == null) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The recorder did not start a preview.',
      );
    }
    return _parsePreview(result);
  }

  @override
  Future<void> stopPreview(int textureId) async {
    await _invoke<void>('stopPreview', {'textureId': textureId});
  }

  static PreviewInfo _parsePreview(Map<Object?, Object?> map) => PreviewInfo(
    textureId: (map['textureId'] as num).toInt(),
    width: map['width'] as int,
    height: map['height'] as int,
    active: map['active'] == true,
  );

  @override
  Future<bool> openAppSettings() async =>
      await _invoke<bool>('openAppSettings') ?? false;

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await methodChannel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw RecorderException(RecorderErrorCode.fromWire(e.code), e.message);
    }
  }

  static RecorderStatus _parseStatus(String? status) => switch (status) {
    'initializing' => RecorderStatus.initializing,
    'recording' => RecorderStatus.recording,
    'stopped' => RecorderStatus.stopped,
    'error' => RecorderStatus.error,
    _ => RecorderStatus.notInitialized,
  };

  static RecorderEvent _parseEvent(dynamic event) {
    final map = event as Map<Object?, Object?>;
    if (map['type'] == 'preview') {
      return RecorderEvent.preview(_parsePreview(map));
    }
    if (map['type'] == 'warning') {
      return RecorderEvent.warning(
        RecorderWarning(
          RecorderWarningCode.fromWire(map['warningCode'] as String?),
          map['warningMessage'] as String?,
        ),
      );
    }
    final status = _parseStatus(map['status'] as String?);
    final errorCode = map['errorCode'] as String?;
    final mediaUri = map['mediaUri'] as String?;
    return RecorderEvent(
      status,
      errorCode == null
          ? null
          : RecorderException(
            RecorderErrorCode.fromWire(errorCode),
            map['errorMessage'] as String?,
            mediaUri == null
                ? null
                : RecordedMedia(
                  uri: mediaUri,
                  path: map['mediaPath'] as String?,
                  kind: _parseKind(map['mediaKind']),
                  hasLocation: map['mediaHasLocation'] == true,
                ),
          ),
    );
  }
}
