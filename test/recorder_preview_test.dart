import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePlatform extends FlutterBackgroundVideoRecorderPlatform
    with MockPlatformInterfaceMixin {
  final events = StreamController<RecorderEvent>.broadcast();
  final started =
      <
        ({
          CameraFacing facing,
          String? cameraId,
          VideoResolution? resolution,
          bool mirror,
          double zoom,
        })
      >[];
  final stopped = <int>[];
  var nextId = 1;
  var active = true;
  Object? startError;

  @override
  Stream<RecorderEvent> get recorderEvents => events.stream;

  @override
  Future<PreviewInfo> startPreview({
    required CameraFacing cameraFacing,
    String? cameraId,
    VideoResolution? resolution,
    bool mirrorFront = true,
    double initialZoom = 1.0,
  }) async {
    started.add((
      facing: cameraFacing,
      cameraId: cameraId,
      resolution: resolution,
      mirror: mirrorFront,
      zoom: initialZoom,
    ));
    if (startError != null) throw startError!;
    return PreviewInfo(
      textureId: nextId++,
      width: 720,
      height: 1280,
      active: active,
    );
  }

  @override
  Future<void> stopPreview(int textureId) async => stopped.add(textureId);
}

void main() {
  late _FakePlatform platform;

  setUp(() {
    platform = _FakePlatform();
    FlutterBackgroundVideoRecorderPlatform.instance = platform;
  });

  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets(
    'shows the camera picture as a texture with the right aspect ratio',
    (tester) async {
      await tester.pumpWidget(
        host(const RecorderPreview(cameraFacing: CameraFacing.rearCamera)),
      );
      await tester.pump();

      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, 1);
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        720 / 1280,
      );
      expect(platform.started.single.facing, CameraFacing.rearCamera);
    },
  );

  testWidgets(
    'hiding the preview is removing the widget: the texture is released',
    (tester) async {
      await tester.pumpWidget(
        host(const RecorderPreview(cameraFacing: CameraFacing.rearCamera)),
      );
      await tester.pump();
      expect(platform.stopped, isEmpty);

      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump();

      expect(find.byType(Texture), findsNothing);
      expect(platform.stopped, [1]);
    },
  );

  testWidgets('showing it again starts a new preview', (tester) async {
    await tester.pumpWidget(
      host(const RecorderPreview(cameraFacing: CameraFacing.rearCamera)),
    );
    await tester.pump();
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpWidget(
      host(const RecorderPreview(cameraFacing: CameraFacing.rearCamera)),
    );
    await tester.pump();

    expect(platform.started, hasLength(2));
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 2);
  });

  testWidgets('changing the camera or size restarts the preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const RecorderPreview(cameraFacing: CameraFacing.rearCamera)),
    );
    await tester.pump();
    await tester.pumpWidget(
      host(
        const RecorderPreview(
          cameraFacing: CameraFacing.frontCamera,
          resolution: VideoResolution(1440, 1080),
        ),
      ),
    );
    await tester.pump();

    expect(platform.stopped, [1]);
    expect(platform.started.last.facing, CameraFacing.frontCamera);
    expect(platform.started.last.resolution, const VideoResolution(1440, 1080));
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 2);
  });

  testWidgets('a picture that is not live shows the placeholder', (
    tester,
  ) async {
    platform.active = false;
    await tester.pumpWidget(
      host(
        const RecorderPreview(
          cameraFacing: CameraFacing.rearCamera,
          placeholder: Text('no picture'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Texture), findsNothing);
    expect(find.text('no picture'), findsOneWidget);
  });

  testWidgets(
    'the preview follows size and live changes sent by the recorder',
    (tester) async {
      await tester.pumpWidget(
        host(
          const RecorderPreview(
            cameraFacing: CameraFacing.rearCamera,
            placeholder: Text('no picture'),
          ),
        ),
      );
      await tester.pump();

      platform.events.add(
        const RecorderEvent.preview(
          PreviewInfo(textureId: 1, width: 1280, height: 720, active: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        1280 / 720,
      );

      platform.events.add(
        const RecorderEvent.preview(
          PreviewInfo(textureId: 1, width: 1280, height: 720, active: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('no picture'), findsOneWidget);

      // Another preview's events are none of this widget's business.
      platform.events.add(
        const RecorderEvent.preview(
          PreviewInfo(textureId: 99, width: 100, height: 100, active: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('no picture'), findsOneWidget);
    },
  );

  testWidgets('without permission the placeholder stays and nothing crashes', (
    tester,
  ) async {
    platform.startError = const RecorderException(
      RecorderErrorCode.permissionDenied,
    );
    await tester.pumpWidget(
      host(
        const RecorderPreview(
          cameraFacing: CameraFacing.rearCamera,
          placeholder: Text('no picture'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('no picture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a start that finishes after the widget is gone is cleaned up', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const RecorderPreview(cameraFacing: CameraFacing.rearCamera)),
    );
    await tester.pumpWidget(
      host(const SizedBox()),
    ); // removed before the start completed
    await tester.pump();

    expect(platform.stopped, [1]);
  });

  testWidgets(
    'going to the background releases the preview and coming back restarts it',
    (tester) async {
      await tester.pumpWidget(
        host(const RecorderPreview(cameraFacing: CameraFacing.rearCamera)),
      );
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(platform.stopped, [1]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(platform.started, hasLength(2));
    },
  );

  testWidgets('passes the chosen camera and zoom to the preview and restarts '
      'when the camera changes', (tester) async {
    await tester.pumpWidget(
      host(
        const RecorderPreview(
          cameraFacing: CameraFacing.rearCamera,
          cameraId: '2',
          initialZoom: 2.0,
        ),
      ),
    );
    await tester.pump();
    expect(platform.started.last.cameraId, '2');
    expect(platform.started.last.zoom, 2.0);

    await tester.pumpWidget(
      host(
        const RecorderPreview(
          cameraFacing: CameraFacing.rearCamera,
          cameraId: '3',
          initialZoom: 2.0,
        ),
      ),
    );
    await tester.pump();
    expect(platform.started, hasLength(2));
    expect(platform.started.last.cameraId, '3');
  });
}
