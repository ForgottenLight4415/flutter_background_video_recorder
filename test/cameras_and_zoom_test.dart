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
  });

  group('listCameras', () {
    test('reads every field of a camera', () async {
      handler =
          (_) async => [
            {
              'id': '0',
              'position': 'rear',
              'sensorOrientation': 90,
              'focalLengthMm': 6.9,
              'focalLengthEquivalentMm': 24.0,
              'minimumFocusDistance': 10.0,
              'zoomMin': 0.6,
              'zoomMax': 10.0,
              'isLogicalMultiCamera': true,
              'physicalCameraIds': ['2', '3'],
            },
            {
              'id': '1',
              'position': 'front',
              'sensorOrientation': 270,
              'zoomMin': 1.0,
              'zoomMax': 1.0,
            },
            {'id': '20', 'position': 'external', 'sensorOrientation': 0},
          ];

      final cameras = await channel.listCameras();

      expect(cameras.map((camera) => camera.id), ['0', '1', '20']);
      expect(cameras[0].position, CameraPosition.rear);
      expect(cameras[0].zoomRange, const ZoomRange(0.6, 10));
      expect(cameras[0].focalLengthEquivalentMm, 24.0);
      expect(cameras[0].isLogicalMultiCamera, isTrue);
      expect(cameras[0].physicalCameraIds, ['2', '3']);
      expect(cameras[1].position, CameraPosition.front);
      expect(cameras[1].focalLengthMm, isNull);
      expect(cameras[2].position, CameraPosition.external);
      expect(cameras[2].zoomRange, ZoomRange.none);
    });

    test('is empty when the device reports nothing', () async {
      handler = (_) async => null;
      expect(await channel.listCameras(), isEmpty);
    });
  });

  group('camera id', () {
    test('is sent only when set', () async {
      handler = (_) async => 'started';
      await channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      expect((calls.last.arguments as Map).keys, isNot(contains('cameraId')));

      await channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.rearCamera,
        cameraId: '4',
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      expect((calls.last.arguments as Map)['cameraId'], '4');
      // The facing stays as the fallback.
      expect((calls.last.arguments as Map)['cameraFacing'], 'rear');
    });

    test('is sent with the capabilities request and read back', () async {
      handler =
          (_) async => {
            'cameraId': '4',
            'zoomMin': 1.0,
            'zoomMax': 30.0,
            'modes': [
              {
                'width': 1920,
                'height': 1080,
                'frameRates': [30],
              },
            ],
            'codecs': {
              'h264': {'supported': true, 'hardware': true},
              'hevc': {'supported': false, 'hardware': false},
            },
          };

      final capabilities = await channel.getVideoCapabilities(
        CameraFacing.rearCamera,
        cameraId: '4',
      );

      expect(calls.single.arguments, {'cameraFacing': 'rear', 'cameraId': '4'});
      expect(capabilities.cameraId, '4');
      expect(capabilities.zoomRange, const ZoomRange(1, 30));
    });

    test('capabilities without a camera id keep the old request', () async {
      handler =
          (_) async => {'modes': <Object?>[], 'codecs': <String, Object?>{}};
      await channel.getVideoCapabilities(CameraFacing.frontCamera);
      expect(calls.single.arguments, {'cameraFacing': 'front'});
    });

    test('goes with the preview request', () async {
      handler =
          (_) async => {
            'textureId': 1,
            'width': 720,
            'height': 1280,
            'active': true,
          };
      await channel.startPreview(
        cameraFacing: CameraFacing.rearCamera,
        cameraId: '2',
      );
      expect((calls.single.arguments as Map)['cameraId'], '2');
    });
  });

  group('zoom', () {
    test('setZoom sends the ratio and returns the applied one', () async {
      handler = (_) async => 4.0;
      final applied = await channel.setZoom(5.0);
      expect(calls.single.method, 'setZoom');
      expect(calls.single.arguments, {'ratio': 5.0});
      expect(applied, 4.0);
    });

    test('setZoom without an open camera is a RecorderException', () async {
      handler = (_) async {
        throw PlatformException(code: 'camera_not_active', message: 'closed');
      };
      await expectLater(
        channel.setZoom(2),
        throwsA(
          isA<RecorderException>().having(
            (e) => e.code,
            'code',
            RecorderErrorCode.cameraNotActive,
          ),
        ),
      );
    });

    test('initialZoom is only sent when it is not 1', () async {
      handler = (_) async => 'started';
      await channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      expect(
        (calls.last.arguments as Map).keys,
        isNot(contains('initialZoom')),
      );

      await channel.startVideoRecording(
        folderName: 'Clips',
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
        settings: const VideoSettings(initialZoom: 3),
      );
      expect((calls.last.arguments as Map)['initialZoom'], 3.0);
    });

    test('ZoomRange limits and compares', () {
      const range = ZoomRange(0.6, 10);
      expect(range.clamp(0.1), 0.6);
      expect(range.clamp(30), 10);
      expect(range.contains(1), isTrue);
      expect(range.contains(11), isFalse);
      expect(range, const ZoomRange(0.6, 10));
      expect(range.hashCode, const ZoomRange(0.6, 10).hashCode);
    });
  });

  group('lens type', () {
    CameraInfo camera({double? equivalent, double? focus}) => CameraInfo(
      id: '0',
      position: CameraPosition.rear,
      sensorOrientation: 90,
      focalLengthEquivalentMm: equivalent,
      minimumFocusDistance: focus,
    );

    test('is told from the equivalent focal length', () {
      expect(camera(equivalent: 14).lensType, CameraLensType.ultraWide);
      expect(camera(equivalent: 24).lensType, CameraLensType.wide);
      expect(camera(equivalent: 39).lensType, CameraLensType.wide);
      expect(camera(equivalent: 70).lensType, CameraLensType.telephoto);
    });

    test('is a macro camera when it focuses very close', () {
      expect(camera(equivalent: 25, focus: 30).lensType, CameraLensType.macro);
      // An ultra-wide that can focus close is still an ultra-wide.
      expect(
        camera(equivalent: 14, focus: 30).lensType,
        CameraLensType.ultraWide,
      );
      // A main camera with ordinary autofocus is not.
      expect(camera(equivalent: 25, focus: 10).lensType, CameraLensType.wide);
    });

    test('is unknown without a focal length', () {
      expect(camera().lensType, CameraLensType.unknown);
    });
  });

  group('error codes', () {
    test('new codes are mapped from the wire', () {
      expect(
        RecorderErrorCode.fromWire('camera_busy'),
        RecorderErrorCode.cameraBusy,
      );
      expect(
        RecorderErrorCode.fromWire('microphone_busy'),
        RecorderErrorCode.microphoneBusy,
      );
      expect(
        RecorderErrorCode.fromWire('camera_not_active'),
        RecorderErrorCode.cameraNotActive,
      );
      expect(
        RecorderErrorCode.fromWire('permission_permanently_denied'),
        RecorderErrorCode.permissionPermanentlyDenied,
      );
      expect(
        RecorderWarningCode.fromWire('audio_overrun'),
        RecorderWarningCode.audioOverrun,
      );
    });
  });
}
