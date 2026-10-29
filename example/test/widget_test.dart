import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';
import 'package:flutter_background_video_recorder_example/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakePlatform extends FlutterBackgroundVideoRecorderPlatform
    with MockPlatformInterfaceMixin {
  final events = StreamController<RecorderEvent>.broadcast();
  CameraFacing? lastFacing;
  VideoSettings? lastSettings;
  final capabilityRequests = <CameraFacing>[];
  final capabilityCameraIds = <String?>[];
  final startedPreviews = <CameraFacing>[];
  final startedPreviewCameras = <String?>[];
  String? lastCameraId;
  final zooms = <double>[];
  var cameras = <CameraInfo>[];
  final stoppedPreviews = <int>[];
  var audioStarts = 0;
  var settingsOpened = 0;
  var status = RecorderStatus.stopped;
  var startResult = StartRecordingResult.started;

  @override
  Future<RecorderStatus> getRecordingStatus() async => status;

  @override
  Stream<RecorderEvent> get recorderEvents => events.stream;

  @override
  Future<List<CameraInfo>> listCameras() async => cameras;

  @override
  Future<double> setZoom(double ratio) async {
    zooms.add(ratio);
    return ratio;
  }

  // The rear camera does 1080p60; the front one only 720p30. Their defaults differ.
  @override
  Future<VideoCapabilities> getVideoCapabilities(
    CameraFacing cameraFacing, {
    String? cameraId,
  }) async {
    capabilityRequests.add(cameraFacing);
    capabilityCameraIds.add(cameraId);
    const codecs = (
      h264: CodecSupport(supported: true, hardwareAccelerated: true),
      hevc: CodecSupport(supported: true, hardwareAccelerated: false),
    );
    return cameraFacing == CameraFacing.rearCamera
        ? const VideoCapabilities(
          modes: [
            VideoMode(VideoResolution(1920, 1080), [24, 30, 60]),
            VideoMode(VideoResolution(1440, 1080), [24, 30]),
            VideoMode(VideoResolution(1280, 720), [24, 30, 60]),
          ],
          h264: CodecSupport(supported: true, hardwareAccelerated: true),
          hevc: CodecSupport(supported: true, hardwareAccelerated: false),
          defaultResolution: VideoResolution(1920, 1080),
          defaultFrameRate: 60,
        )
        : VideoCapabilities(
          modes: const [
            VideoMode(VideoResolution(1280, 720), [30]),
            VideoMode(VideoResolution(640, 480), [30]),
          ],
          h264: codecs.h264,
          hevc: codecs.hevc,
          defaultResolution: const VideoResolution(1280, 720),
          defaultFrameRate: 30,
        );
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
    lastCameraId = cameraId;
    lastFacing = cameraFacing;
    lastSettings = settings;
    return startResult;
  }

  @override
  Future<StartRecordingResult> startAudioRecording({
    required String folderName,
    required String notificationTitle,
    required String notificationText,
  }) async {
    audioStarts++;
    return startResult;
  }

  @override
  Future<RecordedMedia> stopRecording() async =>
      const RecordedMedia(uri: 'content://media/1', path: '/a.mp4');

  @override
  Future<PreviewInfo> startPreview({
    required CameraFacing cameraFacing,
    String? cameraId,
    VideoResolution? resolution,
    bool mirrorFront = true,
    double initialZoom = 1.0,
  }) async {
    startedPreviews.add(cameraFacing);
    startedPreviewCameras.add(cameraId);
    return PreviewInfo(
      textureId: startedPreviews.length,
      width: 720,
      height: 1280,
      active: true,
    );
  }

  @override
  Future<void> stopPreview(int textureId) async =>
      stoppedPreviews.add(textureId);

  @override
  Future<bool> openAppSettings() async {
    settingsOpened++;
    return true;
  }
}

/// A test on a tall phone screen, with animations off (as for a user who turned them off), so that
/// the pulsing record dot and the like do not keep `pumpAndSettle` waiting.
void tallTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await body(tester);
  });
}

void main() {
  late FakePlatform platform;

  setUp(() {
    platform = FakePlatform();
    FlutterBackgroundVideoRecorderPlatform.instance = platform;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const MyApp(tickInterval: null));
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
  }

  Future<void> closeSheet(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
  }

  // region What is shown

  tallTest('shows what will really be recorded, never a vague default', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('16:9 · 1080p · 60'), findsOneWidget);
    expect(find.textContaining('up to'), findsNothing);
    expect(find.text('Ready'), findsOneWidget);
  });

  tallTest(
    'settings list each ratio with its upright equivalent, sizes and 60 fps',
    (tester) async {
      await pumpApp(tester);
      await openSettings(tester);

      expect(find.text('16:9 · 9:16'), findsOneWidget);
      expect(find.text('4:3 · 3:4'), findsOneWidget);
      expect(find.text('1920 × 1080'), findsOneWidget);
      expect(find.text('1280 × 720'), findsOneWidget);
      expect(find.text('24 fps'), findsOneWidget);
      expect(find.text('30 fps'), findsOneWidget);
      expect(find.text('60 fps'), findsOneWidget);
    },
  );

  tallTest('a camera that cannot do 60 fps does not offer it', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    await openSettings(tester);

    expect(find.text('30 fps'), findsOneWidget);
    expect(find.text('60 fps'), findsNothing);
  });

  // endregion

  // region Camera and choices

  tallTest(
    'capabilities are loaded for the camera, and again when it is switched',
    (tester) async {
      await pumpApp(tester);
      expect(platform.capabilityRequests, [CameraFacing.rearCamera]);

      await tester.tap(find.byTooltip('Switch camera'));
      await tester.pumpAndSettle();

      expect(platform.capabilityRequests, [
        CameraFacing.rearCamera,
        CameraFacing.frontCamera,
      ]);
    },
  );

  tallTest('each camera shows its own default until a size is chosen', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('16:9 · 1080p · 60'), findsOneWidget);

    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    expect(find.text('16:9 · 720p · 30'), findsOneWidget);

    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    expect(find.text('16:9 · 1080p · 60'), findsOneWidget);
  });

  tallTest('a size the user chose is kept when the other camera supports it', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.text('1280 × 720'));
    await tester.pumpAndSettle();
    await closeSheet(tester);

    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();

    expect(find.text('16:9 · 720p · 30'), findsOneWidget);
  });

  tallTest('the chosen ratio, size, frame rate and codec reach the recorder', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.text('4:3 · 3:4'));
    await tester.pumpAndSettle();
    // 1440x1080 cannot do 60 fps, so the rate fell back to 30; pick 24.
    await tester.tap(find.text('24 fps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HEVC'));
    await tester.pumpAndSettle();
    await closeSheet(tester);
    expect(find.text('4:3 · 1080p · 24 · HEVC'), findsOneWidget);

    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();

    final settings = platform.lastSettings!;
    expect(settings.resolution, const VideoResolution(1440, 1080));
    expect(settings.frameRate, 24);
    expect(settings.codec, VideoCodec.hevc);
  });

  tallTest('without any choice the device default is what is asked for', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();

    final settings = platform.lastSettings!;
    expect(settings.resolution, const VideoResolution(1920, 1080));
    expect(settings.frameRate, 60);
    expect(settings.codec, VideoCodec.h264);
    expect(settings.embedLocation, isFalse);
  });

  tallTest('location is opt-in', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.text('Store location in the video'));
    await tester.pumpAndSettle();
    await closeSheet(tester);

    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();

    expect(platform.lastSettings!.embedLocation, isTrue);
  });

  // endregion

  // region Recording

  tallTest('recording follows the recorder: stop button, saved message', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();

    platform.events.add(const RecorderEvent(RecorderStatus.recording));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop recording'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved /a.mp4'), findsOneWidget);
  });

  tallTest('picks up a recording that is already running', (tester) async {
    platform.status = RecorderStatus.recording;
    await pumpApp(tester);

    expect(find.byTooltip('Stop recording'), findsOneWidget);
  });

  tallTest('settings and camera switching are locked while recording', (
    tester,
  ) async {
    platform.status = RecorderStatus.recording;
    await pumpApp(tester);

    IconButton button(String tooltip) => tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(button('Settings').onPressed, isNull);
    expect(button('Switch camera').onPressed, isNull);
    // Hiding the preview stays possible: it does not touch the recording.
    expect(button('Hide preview').onPressed, isNotNull);
  });

  tallTest('a lost camera tells the user where the video was saved', (
    tester,
  ) async {
    await pumpApp(tester);

    platform.events.add(
      const RecorderEvent(
        RecorderStatus.error,
        RecorderException(
          RecorderErrorCode.cameraDisconnected,
          'gone',
          RecordedMedia(uri: 'content://media/9', path: '/b.mp4'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Saved /b.mp4'), findsOneWidget);
    expect(find.text('Error'), findsOneWidget);
  });

  tallTest('warnings are shown', (tester) async {
    await pumpApp(tester);

    platform.events.add(
      const RecorderEvent.warning(
        RecorderWarning(RecorderWarningCode.thermalWarning),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('getting hot'), findsOneWidget);
  });

  // endregion

  // region Permissions

  tallTest('permanent denial offers to open the app settings', (tester) async {
    platform.startResult = StartRecordingResult.permissionPermanentlyDenied;
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    expect(find.text('Permissions needed'), findsOneWidget);

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(platform.settingsOpened, 1);
    expect(find.text('Permissions needed'), findsNothing);
  });

  tallTest('declining the settings prompt does not open settings', (
    tester,
  ) async {
    platform.startResult = StartRecordingResult.permissionPermanentlyDenied;
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(platform.settingsOpened, 0);
  });

  tallTest('a plain denial says what is needed and can be retried', (
    tester,
  ) async {
    platform.startResult = StartRecordingResult.permissionDenied;
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();

    expect(find.textContaining('permissions are required'), findsOneWidget);
    expect(find.byTooltip('Start recording'), findsOneWidget);
  });

  // endregion

  // region Preview and audio

  tallTest(
    'hiding the preview removes the widget and showing it brings it back',
    (tester) async {
      await pumpApp(tester);
      expect(find.byType(RecorderPreview), findsOneWidget);
      expect(platform.startedPreviews, [CameraFacing.rearCamera]);

      await tester.tap(find.byTooltip('Hide preview'));
      await tester.pumpAndSettle();
      expect(find.byType(RecorderPreview), findsNothing);
      expect(find.text('Preview hidden'), findsOneWidget);
      expect(platform.stoppedPreviews, [1]);

      await tester.tap(find.byTooltip('Show preview'));
      await tester.pumpAndSettle();
      expect(find.byType(RecorderPreview), findsOneWidget);
      expect(platform.startedPreviews, hasLength(2));
    },
  );

  tallTest('recordings ask for a preview unless it is switched off', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    expect(platform.lastSettings!.preview, isTrue);

    await openSettings(tester);
    await tester.tap(find.text('Preview while recording'));
    await tester.pumpAndSettle();
    await closeSheet(tester);
    expect(find.byType(RecorderPreview), findsNothing);
    expect(find.byTooltip('Hide preview'), findsNothing);

    await tester.tap(find.byTooltip('Start recording'));
    await tester.pumpAndSettle();
    expect(platform.lastSettings!.preview, isFalse);
  });

  tallTest(
    'audio mode starts an audio recording and drops the camera controls',
    (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();
      expect(find.byType(RecorderPreview), findsNothing);
      expect(find.text('Audio recording'), findsOneWidget);
      expect(find.text('Audio · AAC'), findsOneWidget);
      expect(find.byTooltip('Switch camera'), findsNothing);
      expect(find.byTooltip('Hide preview'), findsNothing);

      await tester.tap(find.byTooltip('Start recording'));
      await tester.pumpAndSettle();

      expect(platform.audioStarts, 1);
      expect(platform.lastSettings, isNull);

      await tester.tap(find.text('Video'));
      await tester.pumpAndSettle();
      expect(find.byType(RecorderPreview), findsOneWidget);
    },
  );

  // endregion
}
