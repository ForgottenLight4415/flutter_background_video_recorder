import 'package:flutter/services.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';
import 'package:flutter_background_video_recorder/src/method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channel = MethodChannelFlutterBackgroundVideoRecorder();
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall call)? handler;

  setUp(() {
    calls.clear();
    handler = null;
    messenger.setMockMethodCallHandler(
      MethodChannelFlutterBackgroundVideoRecorder.methodChannel,
      (call) async {
        calls.add(call);
        return handler?.call(call);
      },
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      MethodChannelFlutterBackgroundVideoRecorder.methodChannel,
      null,
    );
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.eventChannel,
      null,
    );
  });

  test(
    'startVideoRecording sends typed arguments and maps the result',
    () async {
      handler = (_) async => 'permissionPermanentlyDenied';

      final result = await channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.frontCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );

      expect(result, StartRecordingResult.permissionPermanentlyDenied);
      expect(calls.single.method, 'startVideoRecording');
      expect(calls.single.arguments, {
        'folderName': 'Clips',
        'cameraFacing': 'front',
        'notificationTitle': 'Title',
        'notificationText': 'Text',
        'codec': 'h264',
      });
    },
  );

  test('startVideoRecording sends the video settings', () async {
    handler = (_) async => 'started';

    await channel.startVideoRecording(
      folderName: 'Clips',
      cameraFacing: CameraFacing.rearCamera,
      notificationTitle: 'Title',
      notificationText: 'Text',
      settings: const VideoSettings(
        resolution: VideoResolution(1280, 720),
        frameRate: 60,
        codec: VideoCodec.hevc,
        bitrate: 8000000,
        embedLocation: true,
      ),
    );

    expect(calls.single.arguments, {
      'folderName': 'Clips',
      'cameraFacing': 'rear',
      'notificationTitle': 'Title',
      'notificationText': 'Text',
      'width': 1280,
      'height': 720,
      'frameRate': 60,
      'codec': 'hevc',
      'bitrate': 8000000,
      'embedLocation': true,
    });
  });

  test(
    'unset video settings are not sent, so the recorder picks defaults',
    () async {
      handler = (_) async => 'started';

      await channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );

      final sent = calls.single.arguments as Map<Object?, Object?>;
      expect(sent.keys, isNot(contains('width')));
      expect(sent.keys, isNot(contains('frameRate')));
      expect(sent.keys, isNot(contains('bitrate')));
      expect(sent.keys, isNot(contains('embedLocation')));
      expect(sent['codec'], 'h264');
    },
  );

  test('an unsupported setting becomes unsupportedConfiguration', () async {
    handler =
        (_) async =>
            throw PlatformException(
              code: 'unsupported_configuration',
              message: '8K is not supported',
            );

    await expectLater(
      channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
        settings: const VideoSettings(resolution: VideoResolution(7680, 4320)),
      ),
      throwsA(
        isA<RecorderException>().having(
          (e) => e.code,
          'code',
          RecorderErrorCode.unsupportedConfiguration,
        ),
      ),
    );
  });

  test('getVideoCapabilities parses modes and codecs', () async {
    handler =
        (_) async => {
          'modes': [
            {
              'width': 1920,
              'height': 1080,
              'frameRates': [24, 30, 60],
            },
            {
              'width': 1440,
              'height': 1080,
              'frameRates': [30],
            },
          ],
          'recommended': {'width': 1920, 'height': 1080, 'frameRate': 60},
          'codecs': {
            'h264': {'supported': true, 'hardware': true},
            'hevc': {'supported': true, 'hardware': false},
          },
        };

    final capabilities = await channel.getVideoCapabilities(
      CameraFacing.frontCamera,
    );

    expect(capabilities.defaultResolution, const VideoResolution(1920, 1080));
    expect(capabilities.defaultFrameRate, 60);

    expect(calls.single.arguments, {'cameraFacing': 'front'});
    expect(capabilities.modes, hasLength(2));
    expect(
      capabilities.modes.first.resolution,
      const VideoResolution(1920, 1080),
    );
    expect(capabilities.modes.first.frameRates, [24, 30, 60]);
    expect(capabilities.h264.hardwareAccelerated, isTrue);
    expect(capabilities.hevc.supported, isTrue);
    expect(capabilities.hevc.hardwareAccelerated, isFalse);
    expect(capabilities.byAspectRatio.keys, ['16:9', '4:3']);
    expect(
      capabilities.modeFor(const VideoResolution(1440, 1080))?.frameRates,
      [30],
    );
    expect(capabilities.modeFor(const VideoResolution(1, 1)), isNull);
  });

  test('aspect ratio labels', () {
    expect(const VideoResolution(1920, 1080).aspectRatioLabel, '16:9');
    expect(const VideoResolution(3840, 2160).aspectRatioLabel, '16:9');
    expect(const VideoResolution(1440, 1080).aspectRatioLabel, '4:3');
    expect(const VideoResolution(1088, 1088).aspectRatioLabel, '1:1');
    expect(const VideoResolution(2560, 1080).aspectRatioLabel, '21:9');
    expect(const VideoResolution(1000, 777).aspectRatioLabel, '1000:777');
  });

  test('the same ratio for a phone held upright', () {
    expect(const VideoResolution(1920, 1080).portraitAspectRatioLabel, '9:16');
    expect(const VideoResolution(1440, 1080).portraitAspectRatioLabel, '3:4');
    expect(const VideoResolution(1088, 1088).portraitAspectRatioLabel, '1:1');
  });

  test('a camera that reports no default leaves it null', () async {
    handler =
        (_) async => {
          'modes': <Object?>[],
          'recommended': null,
          'codecs': {
            'h264': {'supported': true, 'hardware': true},
            'hevc': {'supported': false, 'hardware': false},
          },
        };

    final capabilities = await channel.getVideoCapabilities(
      CameraFacing.rearCamera,
    );

    expect(capabilities.defaultResolution, isNull);
    expect(capabilities.defaultFrameRate, isNull);
  });

  test('stopRecording returns the recorded media', () async {
    handler =
        (_) async => {'uri': 'content://media/1', 'path': '/sdcard/a.mp4'};

    final video = await channel.stopRecording();

    expect(video.uri, 'content://media/1');
    expect(video.path, '/sdcard/a.mp4');
  });

  test(
    'startPreview sends the camera and the video size, and parses the texture',
    () async {
      handler =
          (_) async => {
            'textureId': 7,
            'width': 720,
            'height': 1280,
            'active': true,
          };

      final info = await channel.startPreview(
        cameraFacing: CameraFacing.frontCamera,
        resolution: const VideoResolution(1920, 1080),
        mirrorFront: false,
      );

      expect(calls.single.method, 'startPreview');
      expect(calls.single.arguments, {
        'cameraFacing': 'front',
        'width': 1920,
        'height': 1080,
        'mirrorFront': false,
      });
      expect(info.textureId, 7);
      expect(info.aspectRatio, closeTo(9 / 16, 0.001));
      expect(info.active, isTrue);
    },
  );

  test('stopPreview names the texture', () async {
    await channel.stopPreview(7);
    expect(calls.single.method, 'stopPreview');
    expect(calls.single.arguments, {'textureId': 7});
  });

  test('preview events are told apart from state events', () async {
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success({
            'type': 'preview',
            'textureId': 3,
            'width': 1280,
            'height': 720,
            'active': false,
          });
          sink.success({'type': 'state', 'status': 'recording'});
        },
      ),
    );

    final events = await channel.recorderEvents.take(2).toList();

    expect(events[0].preview?.textureId, 3);
    expect(events[0].preview?.active, isFalse);
    expect(events[1].preview, isNull);
    expect(events[1].status, RecorderStatus.recording);
  });

  test('preview is only sent when asked for', () async {
    handler = (_) async => 'started';
    await channel.startVideoRecording(
      folderName: 'Clips',
      cameraFacing: CameraFacing.rearCamera,
      notificationTitle: 'Title',
      notificationText: 'Text',
    );
    expect((calls.single.arguments as Map).keys, isNot(contains('preview')));

    calls.clear();
    await channel.startVideoRecording(
      folderName: 'Clips',
      cameraFacing: CameraFacing.rearCamera,
      notificationTitle: 'Title',
      notificationText: 'Text',
      settings: const VideoSettings(preview: true),
    );
    expect((calls.single.arguments as Map)['preview'], true);
  });

  test('stopRecording reports whether a position was stored', () async {
    handler =
        (_) async => {'uri': 'content://media/video/1', 'hasLocation': true};
    expect((await channel.stopRecording()).hasLocation, isTrue);

    handler = (_) async => {'uri': 'content://media/video/2'};
    expect((await channel.stopRecording()).hasLocation, isFalse);
  });

  test('a missing location permission declaration is a typed error', () async {
    handler =
        (_) async =>
            throw PlatformException(
              code: 'location_permission_not_declared',
              message: 'declare it',
            );

    await expectLater(
      channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
        settings: const VideoSettings(embedLocation: true),
      ),
      throwsA(
        isA<RecorderException>().having(
          (e) => e.code,
          'code',
          RecorderErrorCode.locationPermissionNotDeclared,
        ),
      ),
    );
  });

  test('stopRecording tells audio from video', () async {
    handler =
        (_) async => {
          'uri': 'content://media/audio/3',
          'path': '/sdcard/Recordings/a.m4a',
          'kind': 'audio',
        };
    final audio = await channel.stopRecording();
    expect(audio.kind, RecordedMediaKind.audio);
    expect(calls.single.method, 'stopRecording');

    handler = (_) async => {'uri': 'content://media/video/3'};
    expect((await channel.stopRecording()).kind, RecordedMediaKind.video);
  });

  test('startAudioRecording sends no camera or video arguments', () async {
    handler = (_) async => 'permissionDenied';

    final result = await channel.startAudioRecording(
      folderName: 'Notes',
      notificationTitle: 'Title',
      notificationText: 'Text',
    );

    expect(result, StartRecordingResult.permissionDenied);
    expect(calls.single.method, 'startAudioRecording');
    expect(calls.single.arguments, {
      'folderName': 'Notes',
      'notificationTitle': 'Title',
      'notificationText': 'Text',
    });
  });

  test('an error event marks audio as the saved media kind', () async {
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success({
            'type': 'state',
            'status': 'error',
            'errorCode': 'storage_full',
            'mediaUri': 'content://media/audio/9',
            'mediaKind': 'audio',
          });
        },
      ),
    );

    final event = await channel.recorderEvents.first;

    expect(event.error?.code, RecorderErrorCode.storageFull);
    expect(event.error?.savedMedia?.kind, RecordedMediaKind.audio);
  });

  test('platform errors become RecorderExceptions', () async {
    handler =
        (_) async =>
            throw PlatformException(code: 'already_recording', message: 'busy');

    await expectLater(
      channel.stopRecording(),
      throwsA(
        isA<RecorderException>()
            .having((e) => e.code, 'code', RecorderErrorCode.alreadyRecording)
            .having((e) => e.message, 'message', 'busy'),
      ),
    );
  });

  test('unknown error codes map to RecorderErrorCode.unknown', () async {
    handler = (_) async => throw PlatformException(code: 'something_new');

    await expectLater(
      channel.getRecordingStatus(),
      throwsA(
        isA<RecorderException>().having(
          (e) => e.code,
          'code',
          RecorderErrorCode.unknown,
        ),
      ),
    );
  });

  test('getRecordingStatus maps wire values', () async {
    for (final entry
        in {
          'initializing': RecorderStatus.initializing,
          'recording': RecorderStatus.recording,
          'stopped': RecorderStatus.stopped,
          'error': RecorderStatus.error,
          'garbage': RecorderStatus.notInitialized,
        }.entries) {
      handler = (_) async => entry.key;
      expect(await channel.getRecordingStatus(), entry.value);
    }
  });

  test('recorderEvents parses status and error payloads', () async {
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success({'status': 'recording'});
          sink.success({
            'status': 'error',
            'errorCode': 'camera_disconnected',
            'errorMessage': 'gone',
          });
        },
      ),
    );

    final events = await channel.recorderEvents.take(2).toList();

    expect(events[0].status, RecorderStatus.recording);
    expect(events[0].error, isNull);
    expect(events[1].status, RecorderStatus.error);
    expect(events[1].error?.code, RecorderErrorCode.cameraDisconnected);
    expect(events[1].error?.message, 'gone');
    expect(events[1].error?.savedMedia, isNull);
  });

  test('an error event can carry the video that was saved before it', () async {
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success({
            'status': 'error',
            'errorCode': 'camera_disconnected',
            'errorMessage': 'gone',
            'mediaUri': 'content://media/7',
            'mediaPath': '/sdcard/Movies/a.mp4',
          });
        },
      ),
    );

    final event = await channel.recorderEvents.first;

    expect(event.error?.code, RecorderErrorCode.cameraDisconnected);
    expect(event.error?.savedMedia?.uri, 'content://media/7');
    expect(event.error?.savedMedia?.path, '/sdcard/Movies/a.mp4');
  });

  test('recorderEvents parses warnings and state events apart', () async {
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success({'type': 'state', 'status': 'recording'});
          sink.success({
            'type': 'warning',
            'warningCode': 'thermal_warning',
            'warningMessage': 'hot',
          });
        },
      ),
    );

    final events = await channel.recorderEvents.take(2).toList();

    expect(events[0].warning, isNull);
    expect(events[0].status, RecorderStatus.recording);
    expect(events[1].warning?.code, RecorderWarningCode.thermalWarning);
    expect(events[1].warning?.message, 'hot');
  });

  test('openAppSettings calls the platform and reports the outcome', () async {
    handler = (_) async => true;
    expect(await channel.openAppSettings(), isTrue);
    expect(calls.single.method, 'openAppSettings');

    handler = (_) async => null;
    expect(await channel.openAppSettings(), isFalse);
  });
}
