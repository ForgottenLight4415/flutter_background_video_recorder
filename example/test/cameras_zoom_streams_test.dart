import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';
import 'package:flutter_background_video_recorder_example/audio_meter.dart';
import 'package:flutter_background_video_recorder_example/camera_picker.dart';
import 'package:flutter_background_video_recorder_example/frame_view.dart';
import 'package:flutter_background_video_recorder_example/main.dart';
import 'package:flutter_background_video_recorder_example/streams_controller.dart';
import 'package:flutter_background_video_recorder_example/streams_panel.dart';
import 'package:flutter_background_video_recorder_example/zoom_selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakePlatform, tallTest;

/// A fake that also opens frame sessions and audio streams.
class StreamsFakePlatform extends FakePlatform {
  final frameController = StreamController<RawFrame>.broadcast();
  final audioController = StreamController<RawAudioChunk>.broadcast();
  var frameOpens = 0;
  var frameCloses = 0;
  var audioOpens = 0;
  var audioCloses = 0;
  RawFrameSettings? lastFrameSettings;
  String? lastFrameCameraId;
  RecorderException? openError;

  @override
  Future<RawFrameSessionInfo> openFrameSession({
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    RawFrameSettings settings = const RawFrameSettings(),
  }) async {
    if (openError != null) throw openError!;
    frameOpens++;
    lastFrameSettings = settings;
    lastFrameCameraId = cameraId;
    return RawFrameSessionInfo(
      cameraId: cameraId ?? '0',
      width: 1280,
      height: 720,
      format: settings.format,
    );
  }

  @override
  Future<void> closeFrameSession() async => frameCloses++;

  @override
  Stream<RawFrame> get rawFrames => frameController.stream;

  @override
  Future<RawAudioSessionInfo> openAudioStream({
    required String notificationTitle,
    required String notificationText,
    RawAudioSettings settings = const RawAudioSettings(),
  }) async {
    if (openError != null) throw openError!;
    audioOpens++;
    return RawAudioSessionInfo(
      sampleRate: settings.sampleRate,
      channels: settings.channels,
      encoding: settings.encoding,
    );
  }

  @override
  Future<void> closeAudioStream() async => audioCloses++;

  @override
  Stream<RawAudioChunk> get rawAudio => audioController.stream;
}

CameraInfo camera(
  String id,
  CameraPosition position, {
  double? equivalent,
  ZoomRange zoom = ZoomRange.none,
  double? focus,
}) => CameraInfo(
  id: id,
  position: position,
  sensorOrientation: 90,
  focalLengthEquivalentMm: equivalent,
  minimumFocusDistance: focus,
  zoomRange: zoom,
);

final threeBack = [
  camera(
    '0',
    CameraPosition.rear,
    equivalent: 24,
    zoom: const ZoomRange(0.6, 10),
  ),
  camera('2', CameraPosition.rear, equivalent: 14, zoom: const ZoomRange(1, 1)),
  camera('3', CameraPosition.rear, equivalent: 70, zoom: const ZoomRange(1, 5)),
  camera('1', CameraPosition.front, equivalent: 24),
];

RawFrame frame({
  int timestamp = 1,
  RawFrameFormat format = RawFrameFormat.yuv420,
}) => RawFrame(
  format: format,
  width: 4,
  height: 2,
  rotationDegrees: 0,
  timestampNs: timestamp,
  planes: [
    RawFramePlane(bytes: Uint8List(8), bytesPerRow: 4, bytesPerPixel: 1),
  ],
);

RawAudioChunk chunk(List<int> shorts) => RawAudioChunk(
  bytes: Uint8List.view(Int16List.fromList(shorts).buffer),
  sampleRate: 44100,
  channels: 1,
  encoding: RawAudioEncoding.pcm16,
  timestampNs: 0,
);

void main() {
  late StreamsFakePlatform platform;

  setUp(() {
    platform = StreamsFakePlatform();
    FlutterBackgroundVideoRecorderPlatform.instance = platform;
  });

  // Closing a session takes a few turns of the event loop to finish.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const MyApp(tickInterval: null));
    await settle(tester);
  }

  Future<void> openStreams(WidgetTester tester) async {
    await tester.tap(find.text('Streams'));
    await settle(tester);
  }

  Finder inCard(String key, Finder finder) =>
      find.descendant(of: find.byKey(Key(key)), matching: finder);

  // region Lens labels

  group('lens labels', () {
    test('each kind of camera has its letters', () {
      final labels = lensLabels(threeBack);
      expect(labels['2']!.letters, 'UW');
      expect(labels['0']!.letters, 'W');
      expect(labels['3']!.letters, 'T');
      expect(labels['1']!.letters, 'F');
      expect(labels['2']!.name, 'Ultra-wide camera');
    });

    test('macro and external cameras', () {
      final labels = lensLabels([
        camera('4', CameraPosition.rear, equivalent: 25, focus: 30),
        camera('20', CameraPosition.external),
      ]);
      expect(labels['4']!.letters, 'M');
      expect(labels['20']!.letters, 'EXT');
    });

    test('cameras of the same kind are numbered', () {
      final labels = lensLabels([
        camera('0', CameraPosition.rear, equivalent: 24),
        camera('5', CameraPosition.rear, equivalent: 70),
        camera('6', CameraPosition.rear, equivalent: 120),
      ]);
      expect(labels['0']!.letters, 'W');
      expect(labels['5']!.letters, 'T1');
      expect(labels['6']!.letters, 'T2');
      expect(labels['6']!.name, 'Telephoto camera 2');
    });
  });

  // endregion

  // region Camera picker

  group('camera picker', () {
    tallTest('is hidden when a side has only one camera', (tester) async {
      platform.cameras = [
        camera('0', CameraPosition.rear, equivalent: 24),
        camera('1', CameraPosition.front, equivalent: 24),
      ];
      await pumpApp(tester);

      expect(find.byType(CameraPicker), findsOneWidget);
      expect(find.text('UW'), findsNothing);
      expect(find.text('W'), findsNothing);
      expect(find.text('F'), findsNothing);
    });

    tallTest('shows a lettered disc for each back camera', (tester) async {
      platform.cameras = threeBack;
      await pumpApp(tester);

      expect(find.text('UW'), findsOneWidget);
      expect(find.text('W'), findsOneWidget);
      expect(find.text('T'), findsOneWidget);
      expect(find.text('F'), findsNothing);
      // Screen readers get the full name, not the letters.
      expect(find.bySemanticsLabel('Ultra-wide camera'), findsOneWidget);
      expect(
        find.text('Wide camera'),
        findsOneWidget,
      ); // the caption of the chosen one
    });

    tallTest('choosing a lens uses that camera everywhere', (tester) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      expect(platform.capabilityCameraIds.last, isNull);

      await tester.tap(find.text('T'));
      await settle(tester);

      expect(platform.capabilityCameraIds.last, '3');
      expect(platform.startedPreviewCameras.last, '3');

      await tester.tap(find.byTooltip('Start recording'));
      await settle(tester);
      expect(platform.lastCameraId, '3');
    });

    tallTest('switching to the front camera leaves the back lenses', (
      tester,
    ) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      await tester.tap(find.text('T'));
      await settle(tester);

      await tester.tap(find.byTooltip('Switch camera'));
      await settle(tester);

      expect(platform.capabilityRequests.last, CameraFacing.frontCamera);
      expect(platform.capabilityCameraIds.last, isNull);
      expect(find.text('UW'), findsNothing);
    });

    tallTest('is locked while recording', (tester) async {
      platform.cameras = threeBack;
      platform.status = RecorderStatus.recording;
      await pumpApp(tester);
      final requests = platform.capabilityRequests.length;

      await tester.tap(find.text('T'));
      await settle(tester);

      expect(platform.capabilityRequests, hasLength(requests));
    });
  });

  // endregion

  // region Zoom

  group('zoom', () {
    tallTest('offers the presets the camera supports', (tester) async {
      platform.cameras = threeBack;
      await pumpApp(tester);

      // The main camera zooms from 0.6x to 10x.
      for (final label in ['0.6x', '1x', '2x', '3x', '5x']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('50x'), findsNothing);
      expect(find.text('100x'), findsNothing);
    });

    tallTest('a camera with a long zoom offers the big values', (tester) async {
      platform.cameras = [
        camera(
          '0',
          CameraPosition.rear,
          equivalent: 24,
          zoom: const ZoomRange(1, 100),
        ),
      ];
      await pumpApp(tester);

      for (final label in ['1x', '2x', '3x', '5x', '50x', '100x']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('0.6x'), findsNothing);
    });

    tallTest('is hidden for a camera that cannot zoom', (tester) async {
      platform.cameras = [camera('0', CameraPosition.rear, equivalent: 24)];
      await pumpApp(tester);

      expect(find.byKey(const Key('zoom-discs')), findsNothing);
    });

    tallTest('tapping a disc zooms to its value', (tester) async {
      platform.cameras = threeBack;
      await pumpApp(tester);

      await tester.tap(find.text('3x'));
      await settle(tester);

      expect(platform.zooms.last, 3.0);
      // The disc in use shows the value in yellow.
      expect(find.text('3x'), findsOneWidget);
    });

    tallTest('dragging across the discs turns them into a wheel', (
      tester,
    ) async {
      platform.cameras = threeBack;
      await pumpApp(tester);

      double opacity(String key) =>
          tester.widget<AnimatedOpacity>(find.byKey(Key(key))).opacity;
      expect(opacity('zoom-discs'), 1);
      expect(opacity('zoom-wheel'), 0);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('zoom-discs'))),
      );
      // The first movement only starts the drag.
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();

      expect(opacity('zoom-discs'), 0);
      expect(opacity('zoom-wheel'), 1);
      // Dragging left turns the wheel towards higher values, in small steps.
      expect(platform.zooms, isNotEmpty);
      expect(platform.zooms.last, greaterThan(1.0));
      expect(platform.zooms.last, lessThan(2.0));

      await gesture.up();
      await settle(tester);
      expect(opacity('zoom-discs'), 1);
      expect(opacity('zoom-wheel'), 0);
    });

    tallTest('dragging the other way zooms out, down to the limit', (
      tester,
    ) async {
      platform.cameras = threeBack;
      await pumpApp(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('zoom-discs'))),
      );
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);

      expect(platform.zooms.last, closeTo(0.6, 0.0001));
    });

    tallTest('stays available while recording', (tester) async {
      platform.cameras = threeBack;
      platform.status = RecorderStatus.recording;
      await pumpApp(tester);

      await tester.tap(find.text('2x'));
      await settle(tester);

      expect(platform.zooms.last, 2.0);
    });

    tallTest('the chosen zoom starts the next recording', (tester) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      await tester.tap(find.text('2x'));
      await settle(tester);

      await tester.tap(find.byTooltip('Start recording'));
      await settle(tester);

      expect(platform.lastSettings!.initialZoom, 2.0);
    });

    tallTest('changing the camera starts again at 1x', (tester) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      await tester.tap(find.text('3x'));
      await settle(tester);

      await tester.tap(find.text('T'));
      await settle(tester);
      await tester.tap(find.byTooltip('Start recording'));
      await settle(tester);

      expect(platform.lastSettings!.initialZoom, 1.0);
    });

    tallTest('is not shown for audio', (tester) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      await tester.tap(find.text('Audio'));
      await settle(tester);

      expect(find.byKey(const Key('zoom-discs')), findsNothing);
      expect(find.text('UW'), findsNothing);
    });

    test('values are written the way people say them', () {
      expect(formatZoom(0.6), '0.6x');
      expect(formatZoom(1), '1x');
      expect(formatZoom(2.04), '2x');
      expect(formatZoom(2.4), '2.4x');
      expect(formatZoom(100), '100x');
    });
  });

  // endregion

  // region Streams mode

  group('streams mode', () {
    tallTest('replaces the capture button with the subscription cards', (
      tester,
    ) async {
      await pumpApp(tester);
      expect(find.byTooltip('Start recording'), findsOneWidget);

      await openStreams(tester);

      expect(find.byTooltip('Start recording'), findsNothing);
      expect(find.byKey(const Key('frames-card')), findsOneWidget);
      expect(find.byKey(const Key('audio-card')), findsOneWidget);
      expect(find.text('Subscribe to a stream to see it here'), findsOneWidget);
    });

    tallTest('subscribing opens the frame session with the chosen format', (
      tester,
    ) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.text('JPEG')));
      await settle(tester);

      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);

      expect(platform.frameOpens, 1);
      expect(platform.lastFrameSettings!.format, RawFrameFormat.jpeg);
      expect(platform.lastFrameCameraId, '0');
      expect(find.text('Streaming'), findsOneWidget);
      expect(
        find.textContaining('Live from stream · 1280×720'),
        findsOneWidget,
      );
    });

    tallTest('the zoom chosen before subscribing starts the session', (
      tester,
    ) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      await tester.tap(find.text('2x'));
      await settle(tester);
      await openStreams(tester);

      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);

      expect(platform.lastFrameSettings!.initialZoom, 2.0);
    });

    tallTest('several listeners share the one session and each counts', (
      tester,
    ) async {
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);
      await tester.tap(inCard('frames-card', find.byTooltip('Add a listener')));
      await settle(tester);

      expect(platform.frameOpens, 1);
      platform.frameController.add(frame(timestamp: 1));
      platform.frameController.add(frame(timestamp: 2));
      await tester.pump();
      await tester.pump();

      expect(find.text('#1: 2'), findsOneWidget);
      expect(find.text('#2: 2'), findsOneWidget);
      expect(find.byKey(const Key('stream-frame')), findsOneWidget);
    });

    tallTest('removing a listener keeps the session until the last one', (
      tester,
    ) async {
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);
      await tester.tap(inCard('frames-card', find.byTooltip('Add a listener')));
      await settle(tester);

      await tester.tap(
        inCard('frames-card', find.byTooltip('Remove a listener')),
      );
      await settle(tester);
      expect(platform.frameCloses, 0);
      expect(find.text('#1: 0'), findsOneWidget);
      expect(find.text('#2: 0'), findsNothing);

      await tester.tap(
        inCard('frames-card', find.byTooltip('Remove a listener')),
      );
      await settle(tester);
      expect(platform.frameCloses, 1);
      expect(find.text('Streaming'), findsNothing);
      expect(find.text('Ready'), findsOneWidget);
    });

    tallTest('the switch off closes the session for every listener', (
      tester,
    ) async {
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);
      await tester.tap(inCard('frames-card', find.byTooltip('Add a listener')));
      await settle(tester);

      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);

      expect(platform.frameCloses, 1);
      expect(find.text('#1: 0'), findsNothing);
    });

    tallTest('the format cannot change while subscribed', (tester) async {
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);

      await tester.tap(inCard('frames-card', find.text('RGBA')));
      await settle(tester);

      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: inCard('frames-card', find.text('RGBA')),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isFalse,
      );
    });

    tallTest('the audio stream has its own session and a level meter', (
      tester,
    ) async {
      await pumpApp(tester);
      await openStreams(tester);

      await tester.tap(inCard('audio-card', find.byType(Switch)));
      await settle(tester);
      expect(platform.audioOpens, 1);
      expect(platform.frameOpens, 0);
      expect(find.byType(AudioMeter), findsOneWidget);

      platform.audioController.add(chunk([12000, -12000, 12000, -12000]));
      await tester.pump();
      await tester.pump();
      expect(find.text('#1: 1'), findsOneWidget);
      expect(find.text('Receiving audio'), findsOneWidget);
    });

    tallTest('both streams can run together', (tester) async {
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);
      await tester.tap(inCard('audio-card', find.byType(Switch)));
      await settle(tester);

      expect(platform.frameOpens, 1);
      expect(platform.audioOpens, 1);
    });

    tallTest('leaving Streams mode closes the sessions', (tester) async {
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);
      await tester.tap(inCard('audio-card', find.byType(Switch)));
      await settle(tester);

      await tester.tap(find.text('Video'));
      await settle(tester);

      expect(platform.frameCloses, 1);
      expect(platform.audioCloses, 1);
      expect(find.byTooltip('Start recording'), findsOneWidget);
    });

    tallTest('a busy camera is explained', (tester) async {
      platform.openError = const RecorderException(
        RecorderErrorCode.cameraBusy,
      );
      await pumpApp(tester);
      await openStreams(tester);

      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);

      expect(find.textContaining('camera is busy'), findsOneWidget);
      expect(find.text('Streaming'), findsNothing);
    });

    tallTest('blocked permissions lead to the settings dialog', (tester) async {
      platform.openError = const RecorderException(
        RecorderErrorCode.permissionPermanentlyDenied,
      );
      await pumpApp(tester);
      await openStreams(tester);

      await tester.tap(inCard('audio-card', find.byType(Switch)));
      await settle(tester);

      expect(find.text('Permissions needed'), findsOneWidget);
    });

    tallTest('the camera picker locks while frames are subscribed', (
      tester,
    ) async {
      platform.cameras = threeBack;
      await pumpApp(tester);
      await openStreams(tester);
      await tester.tap(inCard('frames-card', find.byType(Switch)));
      await settle(tester);
      final requests = platform.capabilityRequests.length;

      await tester.tap(find.text('T'));
      await settle(tester);
      expect(platform.capabilityRequests, hasLength(requests));

      // The zoom does not lock: the camera keeps running while it changes.
      await tester.tap(find.text('3x'));
      await settle(tester);
      expect(platform.zooms.last, 3.0);
    });

    tallTest('the camera can still be flipped when not subscribed', (
      tester,
    ) async {
      await pumpApp(tester);
      await openStreams(tester);

      await tester.tap(find.byTooltip('Switch camera'));
      await settle(tester);

      expect(platform.capabilityRequests.last, CameraFacing.frontCamera);
    });
  });

  // endregion

  // region Helpers

  group('helpers', () {
    test('the loudness of silence and of a loud signal', () {
      expect(chunkLevel(chunk([0, 0, 0, 0])), 0);
      expect(
        chunkLevel(chunk([32767, -32768, 32767, -32768])),
        closeTo(1, 0.01),
      );
      final quiet = chunkLevel(chunk([300, -300, 300, -300]));
      final loud = chunkLevel(chunk([9000, -9000, 9000, -9000]));
      expect(quiet, greaterThan(0));
      expect(loud, greaterThan(quiet));
    });

    test('float samples are measured too', () {
      final samples = Float32List.fromList([0.5, -0.5, 0.5, -0.5]);
      final loud = RawAudioChunk(
        bytes: Uint8List.view(samples.buffer),
        sampleRate: 44100,
        channels: 1,
        encoding: RawAudioEncoding.pcmFloat,
        timestampNs: 0,
      );
      expect(chunkLevel(loud), closeTo(0.5 * 0 + 0.7071, 0.01));
    });

    test('the brightness plane becomes a grey picture, skipping padding', () {
      final yuv = RawFrame(
        format: RawFrameFormat.yuv420,
        width: 2,
        height: 2,
        rotationDegrees: 0,
        timestampNs: 0,
        planes: [
          RawFramePlane(
            bytes: Uint8List.fromList([10, 20, 99, 99, 30, 40, 99, 99]),
            bytesPerRow: 4,
            bytesPerPixel: 1,
          ),
        ],
      );
      expect(yPlaneToRgba(yuv), [
        10,
        10,
        10,
        255,
        20,
        20,
        20,
        255,
        30,
        30,
        30,
        255,
        40,
        40,
        40,
        255,
      ]);
    });

    test('rates are written for people', () {
      expect(formatRate(2.5 * 1024 * 1024), '2.5 MB/s');
      expect(formatRate(340 * 1024), '340 KB/s');
    });
  });

  // endregion
}
