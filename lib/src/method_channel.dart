import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ffi_frame_memory.dart';
import 'models.dart';
import 'platform_interface.dart';
import 'wire.dart';

/// The [FlutterBackgroundVideoRecorderPlatform] that talks to Android over a method channel and
/// an event channel.
class MethodChannelFlutterBackgroundVideoRecorder
    extends FlutterBackgroundVideoRecorderPlatform {
  /// Creates the platform. [frameMemory] reads the frames of a frame session; tests pass their own,
  /// the default reads native memory through `dart:ffi`.
  MethodChannelFlutterBackgroundVideoRecorder({NativeFrameMemory? frameMemory})
    : _frameMemory = frameMemory;

  NativeFrameMemory? _frameMemory;
  NativeFrameMemory get _memory => _frameMemory ??= FfiFrameMemory();

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

  /// The event channel that carries the frames of a frame session.
  @visibleForTesting
  static const EventChannel frameChannel = EventChannel(
    'flutter_background_video_recorder_frames',
  );

  /// The event channel that carries the sound of an audio stream.
  @visibleForTesting
  static const EventChannel audioChannel = EventChannel(
    'flutter_background_video_recorder_audio',
  );

  // Created once so that every listener shares a single native subscription.
  late final Stream<RecorderEvent> _events = eventChannel
      .receiveBroadcastStream()
      .map(eventFromWire);

  // The native side tells a session has ended with a 'closed' event (null here) instead of
  // closing the channel, because a closed event channel could not be listened to again.
  late final Stream<RawFrame?> _frameEvents = frameChannel
      .receiveBroadcastStream()
      .map((event) => frameFromWire(event, _memory));
  late final Stream<RawAudioChunk?> _audioEvents = audioChannel
      .receiveBroadcastStream()
      .map(audioChunkFromWire);

  @override
  Future<RecorderStatus> getRecordingStatus() async {
    final status = await _invoke<String>('getRecordingStatus');
    return statusFromWire(status);
  }

  @override
  Stream<RecorderEvent> get recorderEvents => _events;

  @override
  Future<List<CameraInfo>> listCameras() async {
    final result = await _invoke<List<Object?>>('listCameras');
    return [
      for (final raw in result ?? const <Object?>[])
        cameraFromWire(raw as Map<Object?, Object?>),
    ];
  }

  @override
  Future<double> setZoom(double ratio) async {
    final applied = await _invoke<num>('setZoom', {'ratio': ratio});
    return applied?.toDouble() ?? ratio;
  }

  @override
  Future<VideoCapabilities> getVideoCapabilities(
    CameraFacing cameraFacing, {
    String? cameraId,
  }) async {
    final result =
        await _invoke<Map<Object?, Object?>>('getVideoCapabilities', {
          'cameraFacing': facingToWire(cameraFacing),
          if (cameraId != null) 'cameraId': cameraId,
        });
    if (result == null) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The recorder did not report any capabilities.',
      );
    }
    return capabilitiesFromWire(result);
  }

  @override
  Future<StartRecordingResult> startVideoRecording({
    required String folderName,
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    VideoSettings settings = const VideoSettings(),
  }) async {
    final result = await _invoke<String>('startVideoRecording', {
      'folderName': folderName,
      'cameraFacing': facingToWire(cameraFacing),
      if (cameraId != null) 'cameraId': cameraId,
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
      if (settings.initialZoom != 1.0) 'initialZoom': settings.initialZoom,
    });
    return startResultFromWire(result);
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
    return startResultFromWire(result);
  }

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
      kind: mediaKindFromWire(result?['kind']),
      hasLocation: result?['hasLocation'] == true,
    );
  }

  @override
  Future<PreviewInfo> startPreview({
    required CameraFacing cameraFacing,
    String? cameraId,
    VideoResolution? resolution,
    bool mirrorFront = true,
    double initialZoom = 1.0,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('startPreview', {
      'cameraFacing': facingToWire(cameraFacing),
      if (cameraId != null) 'cameraId': cameraId,
      if (initialZoom != 1.0) 'initialZoom': initialZoom,
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
    return previewFromWire(result);
  }

  @override
  Future<void> stopPreview(int textureId) async {
    await _invoke<void>('stopPreview', {'textureId': textureId});
  }

  @override
  Future<RawFrameSessionInfo> openFrameSession({
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    RawFrameSettings settings = const RawFrameSettings(),
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('openFrameSession', {
      'cameraFacing': facingToWire(cameraFacing),
      if (cameraId != null) 'cameraId': cameraId,
      'notificationTitle': notificationTitle,
      'notificationText': notificationText,
      'format': settings.format.name,
      if (settings.resolution != null) ...{
        'width': settings.resolution!.width,
        'height': settings.resolution!.height,
      },
      if (settings.maxFrameRate != null) 'maxFrameRate': settings.maxFrameRate,
      'jpegQuality': settings.jpegQuality,
      if (settings.initialZoom != 1.0) 'initialZoom': settings.initialZoom,
    });
    if (result == null) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The recorder did not open a frame session.',
      );
    }
    return RawFrameSessionInfo(
      cameraId: result['cameraId'] as String,
      width: result['width'] as int,
      height: result['height'] as int,
      format: frameFormatFromWire(result['format']),
    );
  }

  @override
  Future<void> closeFrameSession() async {
    await _invoke<void>('closeFrameSession');
  }

  @override
  Stream<RawFrame> get rawFrames => _asRecorderErrors(
    _frameEvents.takeWhile((frame) => frame != null).map((frame) => frame!),
  );

  @override
  Future<RawAudioSessionInfo> openAudioStream({
    required String notificationTitle,
    required String notificationText,
    RawAudioSettings settings = const RawAudioSettings(),
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('openAudioStream', {
      'notificationTitle': notificationTitle,
      'notificationText': notificationText,
      'sampleRate': settings.sampleRate,
      'channels': settings.channels,
      'encoding': settings.encoding.name,
      'source': settings.source.name,
      'chunkMs': settings.chunkDuration.inMilliseconds,
    });
    if (result == null) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The recorder did not open an audio stream.',
      );
    }
    return RawAudioSessionInfo(
      sampleRate: result['sampleRate'] as int,
      channels: result['channels'] as int,
      encoding: audioEncodingFromWire(result['encoding']),
    );
  }

  @override
  Future<void> closeAudioStream() async {
    await _invoke<void>('closeAudioStream');
  }

  @override
  Stream<RawAudioChunk> get rawAudio => _asRecorderErrors(
    _audioEvents.takeWhile((chunk) => chunk != null).map((chunk) => chunk!),
  );

  /// Native failures of a session arrive as [PlatformException]s; apps get [RecorderException]s.
  /// Every listener gets its own subscription to [source], so listeners come and go freely.
  static Stream<T> _asRecorderErrors<T>(Stream<T> source) =>
      Stream<T>.multi((controller) {
        final subscription = source.listen(
          controller.addSync,
          onError: (Object error, StackTrace stackTrace) {
            controller.addErrorSync(
              error is PlatformException
                  ? RecorderException(
                    RecorderErrorCode.fromWire(error.code),
                    error.message,
                  )
                  : error,
              stackTrace,
            );
          },
          onDone: controller.closeSync,
        );
        controller.onCancel = subscription.cancel;
      }, isBroadcast: true);

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
}
