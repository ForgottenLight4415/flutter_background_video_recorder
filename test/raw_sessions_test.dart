import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';
import 'package:flutter_background_video_recorder/src/method_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Stands in for native memory: slots are stretches of one array, and "addresses" are positions in it.
class FakeFrameMemory implements NativeFrameMemory {
  FakeFrameMemory([int size = 256]) : arena = Uint8List(size);

  final Uint8List arena;
  final released = <(int, int)>[];

  @override
  Uint8List view(int address, int length) =>
      Uint8List.sublistView(arena, address, address + length);

  @override
  void release(int ringId, int slot) => released.add((ringId, slot));
}

/// What the Android side sends for a frame: where it lies, not the pixels. Three planes of four
/// bytes at offsets 0, 16 and 32 of the slot (a JPEG or RGBA frame has one).
Map<String, Object?> _frameEvent({
  int slot = 0,
  String format = 'yuv420',
  int rotation = 90,
  int timestamp = 1000,
  int dropped = 0,
  int ring = 7,
}) => {
  'type': 'frame',
  'ring': ring,
  'slot': slot,
  'address': slot * 64,
  'format': format,
  'width': 4,
  'height': 2,
  'rotation': rotation,
  'timestampNs': timestamp,
  'dropped': dropped,
  'planes': [
    for (var i = 0; i < (format == 'yuv420' ? 3 : 1); i++)
      {'offset': i * 16, 'length': 4, 'bytesPerRow': 4, 'bytesPerPixel': 1},
  ],
};

Map<String, Object?> _audioEvent({int timestamp = 5}) => {
  'type': 'chunk',
  'bytes': Uint8List.fromList([1, 0, 2, 0]),
  'sampleRate': 44100,
  'channels': 1,
  'encoding': 'pcm16',
  'timestampNs': timestamp,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final memory = FakeFrameMemory();
  final channel = MethodChannelFlutterBackgroundVideoRecorder(
    frameMemory: memory,
  );
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall call)? handler;
  MockStreamHandlerEventSink? frameSink;
  MockStreamHandlerEventSink? audioSink;
  var frameListens = 0;
  var frameCancels = 0;

  setUp(() {
    calls.clear();
    memory.released.clear();
    memory.arena.fillRange(0, memory.arena.length, 0);
    handler = null;
    frameSink = null;
    audioSink = null;
    frameListens = 0;
    frameCancels = 0;
    messenger.setMockMethodCallHandler(
      MethodChannelFlutterBackgroundVideoRecorder.methodChannel,
      (call) async {
        calls.add(call);
        return handler?.call(call);
      },
    );
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.frameChannel,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          frameListens++;
          frameSink = sink;
        },
        onCancel: (arguments) => frameCancels++,
      ),
    );
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.audioChannel,
      MockStreamHandler.inline(onListen: (arguments, sink) => audioSink = sink),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      MethodChannelFlutterBackgroundVideoRecorder.methodChannel,
      null,
    );
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.frameChannel,
      null,
    );
    messenger.setMockStreamHandler(
      MethodChannelFlutterBackgroundVideoRecorder.audioChannel,
      null,
    );
  });

  group('frame session over the channel', () {
    test('openFrameSession sends the settings and reads the result', () async {
      handler =
          (_) async => {
            'cameraId': '2',
            'width': 1280,
            'height': 720,
            'format': 'jpeg',
          };

      final info = await channel.openFrameSession(
        cameraFacing: CameraFacing.rearCamera,
        cameraId: '2',
        notificationTitle: 'Title',
        notificationText: 'Text',
        settings: const RawFrameSettings(
          format: RawFrameFormat.jpeg,
          resolution: VideoResolution(1280, 720),
          maxFrameRate: 15,
          jpegQuality: 60,
          initialZoom: 2,
        ),
      );

      expect(calls.single.method, 'openFrameSession');
      expect(calls.single.arguments, {
        'cameraFacing': 'rear',
        'cameraId': '2',
        'notificationTitle': 'Title',
        'notificationText': 'Text',
        'format': 'jpeg',
        'width': 1280,
        'height': 720,
        'maxFrameRate': 15,
        'jpegQuality': 60,
        'initialZoom': 2.0,
      });
      expect(info.cameraId, '2');
      expect(info.width, 1280);
      expect(info.format, RawFrameFormat.jpeg);
    });

    test('the defaults are yuv420 and nothing else', () async {
      handler =
          (_) async => {
            'cameraId': '0',
            'width': 1280,
            'height': 720,
            'format': 'yuv420',
          };
      await channel.openFrameSession(
        cameraFacing: CameraFacing.frontCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      expect(calls.single.arguments, {
        'cameraFacing': 'front',
        'notificationTitle': 'Title',
        'notificationText': 'Text',
        'format': 'yuv420',
        'jpegQuality': 80,
      });
    });

    test('a busy camera is a RecorderException', () async {
      handler = (_) async {
        throw PlatformException(code: 'camera_busy', message: 'in use');
      };
      await expectLater(
        channel.openFrameSession(
          cameraFacing: CameraFacing.rearCamera,
          notificationTitle: 'Title',
          notificationText: 'Text',
        ),
        throwsA(
          isA<RecorderException>().having(
            (e) => e.code,
            'code',
            RecorderErrorCode.cameraBusy,
          ),
        ),
      );
    });

    test('frames are read in place from native memory', () async {
      // Plane 0 of slot 1 holds 10..13 and plane 2 holds 30..33.
      for (var i = 0; i < 4; i++) {
        memory.arena[64 + i] = 10 + i;
        memory.arena[64 + 32 + i] = 30 + i;
      }
      final frames = <RawFrame>[];
      final subscription = channel.rawFrames.listen(frames.add);
      await pumpEventQueue();

      frameSink!.success(_frameEvent(slot: 1, dropped: 3));
      await pumpEventQueue();

      final frame = frames.single;
      expect(frame.format, RawFrameFormat.yuv420);
      expect(frame.planes, hasLength(3));
      expect(frame.planes[0].bytes, [10, 11, 12, 13]);
      expect(frame.planes[2].bytes, [30, 31, 32, 33]);
      expect(frame.planes[0].bytesPerRow, 4);
      expect(frame.rotationDegrees, 90);
      expect(frame.timestampNs, 1000);
      expect(frame.droppedFrames, 3);
      expect(frame.uprightSize, (width: 2, height: 4));
      // A view, not a copy: it sees what the camera side writes next.
      memory.arena[64] = 99;
      expect(frame.planes[0].bytes[0], 99);
      await subscription.cancel();
    });

    test('single-plane formats are parsed too', () async {
      final frames = <RawFrame>[];
      final subscription = channel.rawFrames.listen(frames.add);
      await pumpEventQueue();

      frameSink!.success(_frameEvent(format: 'jpeg', rotation: 0));
      frameSink!.success(_frameEvent(slot: 1, format: 'rgba', rotation: 270));
      await pumpEventQueue();

      expect(frames.map((f) => f.format), [
        RawFrameFormat.jpeg,
        RawFrameFormat.rgba,
      ]);
      expect(frames[0].planes, hasLength(1));
      expect(frames[1].uprightSize, (width: 2, height: 4));
      await subscription.cancel();
    });

    test('an event that cannot be read still gives its slot back', () async {
      final frames = <RawFrame>[];
      final errors = <Object>[];
      final subscription = channel.rawFrames.listen(
        frames.add,
        onError: errors.add,
      );
      await pumpEventQueue();

      // The plane lacks its length.
      final broken = _frameEvent(slot: 2, ring: 9);
      (broken['planes'] as List).first.remove('length');
      frameSink!.success(broken);
      await pumpEventQueue();

      expect(frames, isEmpty);
      expect(errors, hasLength(1));
      expect(memory.released, [(9, 2)]);
      await subscription.cancel();
    });

    test('two listeners share one native subscription and both get '
        'every frame', () async {
      final first = <int>[];
      final second = <int>[];
      final a = channel.rawFrames.listen((f) => first.add(f.timestampNs));
      final b = channel.rawFrames.listen((f) => second.add(f.timestampNs));
      await pumpEventQueue();

      frameSink!.success(_frameEvent(timestamp: 1));
      frameSink!.success(_frameEvent(timestamp: 2));
      await pumpEventQueue();
      expect(first, [1, 2]);
      expect(second, [1, 2]);
      expect(frameListens, 1);

      await a.cancel();
      frameSink!.success(_frameEvent(timestamp: 3));
      await pumpEventQueue();
      expect(first, [1, 2]);
      expect(second, [1, 2, 3]);
      expect(frameCancels, 0);

      await b.cancel();
      await pumpEventQueue();
      expect(frameCancels, 1);
    });

    test('the closed event ends the stream, and it can be listened to '
        'again', () async {
      var done = false;
      channel.rawFrames.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();
      frameSink!.success({'type': 'closed'});
      await pumpEventQueue();
      expect(done, isTrue);

      // A later session listens again.
      final frames = <RawFrame>[];
      final later = channel.rawFrames.listen(frames.add);
      await pumpEventQueue();
      frameSink!.success(_frameEvent());
      await pumpEventQueue();
      expect(frames, hasLength(1));
      await later.cancel();
    });

    test('a native failure is a RecorderException on the stream', () async {
      final errors = <Object>[];
      final subscription = channel.rawFrames.listen(
        (_) {},
        onError: errors.add,
      );
      await pumpEventQueue();
      frameSink!.error(code: 'camera_disconnected', message: 'lost');
      await pumpEventQueue();

      expect(errors.single, isA<RecorderException>());
      expect(
        (errors.single as RecorderException).code,
        RecorderErrorCode.cameraDisconnected,
      );
      await subscription.cancel();
    });

    test('closeFrameSession calls the platform', () async {
      await channel.closeFrameSession();
      expect(calls.single.method, 'closeFrameSession');
    });
  });

  group('audio stream over the channel', () {
    test('openAudioStream sends the settings and reads the result', () async {
      handler =
          (_) async => {
            'sampleRate': 48000,
            'channels': 2,
            'encoding': 'pcmFloat',
          };

      final info = await channel.openAudioStream(
        notificationTitle: 'Title',
        notificationText: 'Text',
        settings: const RawAudioSettings(
          sampleRate: 48000,
          channels: 2,
          encoding: RawAudioEncoding.pcmFloat,
          source: RawAudioSource.unprocessed,
          chunkDuration: Duration(milliseconds: 40),
        ),
      );

      expect(calls.single.arguments, {
        'notificationTitle': 'Title',
        'notificationText': 'Text',
        'sampleRate': 48000,
        'channels': 2,
        'encoding': 'pcmFloat',
        'source': 'unprocessed',
        'chunkMs': 40,
      });
      expect(info.sampleRate, 48000);
      expect(info.channels, 2);
      expect(info.encoding, RawAudioEncoding.pcmFloat);
    });

    test('chunks are parsed and the stream ends when closed', () async {
      final chunks = <RawAudioChunk>[];
      var done = false;
      channel.rawAudio.listen(chunks.add, onDone: () => done = true);
      await pumpEventQueue();

      audioSink!.success(_audioEvent(timestamp: 9));
      audioSink!.success({'type': 'closed'});
      await pumpEventQueue();

      expect(chunks.single.bytes, [1, 0, 2, 0]);
      expect(chunks.single.sampleRate, 44100);
      expect(chunks.single.encoding, RawAudioEncoding.pcm16);
      expect(chunks.single.timestampNs, 9);
      expect(chunks.single.frameCount, 2);
      expect(done, isTrue);
    });

    test('a chunk knows its length', () {
      final chunk = RawAudioChunk(
        bytes: Uint8List(44100 * 2 ~/ 50),
        sampleRate: 44100,
        channels: 1,
        encoding: RawAudioEncoding.pcm16,
        timestampNs: 0,
      );
      expect(chunk.duration, const Duration(milliseconds: 20));
      expect(chunk.bytesPerSample, 2);
    });
  });

  group('frame lifetime', () {
    late _FakeSessionPlatform platform;
    late FakeFrameMemory arena;
    const recorder = FlutterBackgroundVideoRecorder();

    Future<RawFrameSession> open() => recorder.openFrameSession(
      cameraFacing: CameraFacing.rearCamera,
      notificationTitle: 'Title',
      notificationText: 'Text',
    );

    setUp(() {
      platform = _FakeSessionPlatform();
      arena = FakeFrameMemory();
      FlutterBackgroundVideoRecorderPlatform.instance = platform;
    });

    tearDown(() {
      FlutterBackgroundVideoRecorderPlatform.instance =
          MethodChannelFlutterBackgroundVideoRecorder();
    });

    test('a frame is usable in the listener and released right after', () async {
      final session = await open();
      List<int>? seen;
      late RawFrame delivered;
      session.frames.listen((frame) {
        delivered = frame;
        seen = frame.planes.first.bytes.toList();
        expect(arena.released, isEmpty);
      });
      arena.arena.setRange(0, 4, [1, 2, 3, 4]);

      platform.frames.add(_nativeFrame(arena));

      expect(seen, [1, 2, 3, 4]);
      expect(arena.released, [(7, 0)]);
      expect(delivered.isReleased, isTrue);
      // The mistake of keeping a frame is caught instead of reading someone else's picture.
      expect(() => delivered.planes, throwsStateError);
      await session.close();
    });

    test(
      'a frame is released once, after every listener has seen it',
      () async {
        final session = await open();
        final order = <String>[];
        session.frames.listen((_) => order.add('first'));
        session.frames.listen((frame) {
          order.add('second');
          expect(frame.planes, hasLength(1));
          expect(arena.released, isEmpty);
        });

        platform.frames.add(_nativeFrame(arena));

        expect(order, ['first', 'second']);
        expect(arena.released, hasLength(1));
        await session.close();
      },
    );

    test('a retained frame stays valid until it is released', () async {
      final session = await open();
      RawFrame? kept;
      session.frames.listen((frame) {
        frame.retain();
        kept = frame;
      });
      arena.arena.setRange(0, 4, [5, 6, 7, 8]);

      platform.frames.add(_nativeFrame(arena));
      await pumpEventQueue();

      expect(arena.released, isEmpty);
      expect(kept!.isReleased, isFalse);
      expect(kept!.planes.first.bytes, [5, 6, 7, 8]);

      kept!.release();
      expect(arena.released, [(7, 0)]);
      expect(kept!.isReleased, isTrue);
      // Releasing again, or too often, changes nothing.
      kept!.release();
      expect(arena.released, hasLength(1));
      await session.close();
    });

    test('a frame can be retained more than once', () async {
      final session = await open();
      RawFrame? kept;
      session.frames.listen((frame) {
        frame
          ..retain()
          ..retain();
        kept = frame;
      });
      platform.frames.add(_nativeFrame(arena));

      kept!.release();
      expect(arena.released, isEmpty);
      kept!.release();
      expect(arena.released, [(7, 0)]);
      await session.close();
    });

    test('a released frame cannot be retained', () async {
      final session = await open();
      late RawFrame delivered;
      session.frames.listen((frame) => delivered = frame);
      platform.frames.add(_nativeFrame(arena));

      expect(delivered.retain, throwsStateError);
      await session.close();
    });

    test('toOwned copies the pixels and outlives the frame', () async {
      final session = await open();
      late RawFrame copy;
      session.frames.listen((frame) => copy = frame.toOwned());
      arena.arena.setRange(0, 4, [9, 8, 7, 6]);

      platform.frames.add(_nativeFrame(arena));
      arena.arena.setRange(0, 4, [0, 0, 0, 0]); // the slot is reused

      expect(copy.isReleased, isFalse);
      expect(copy.planes.first.bytes, [9, 8, 7, 6]);
      await session.close();
    });

    test('a listener that throws does not keep the slot', () async {
      final session = await open();
      final errors = <Object>[];

      await runZonedGuarded(() async {
        session.frames.listen((_) => throw StateError('listener bug'));
        platform.frames.add(_nativeFrame(arena));
        await pumpEventQueue();
      }, (error, stack) => errors.add(error));

      expect(errors, isNotEmpty);
      expect(arena.released, [(7, 0)]);
      await session.close();
    });

    test('a frame that owns its bytes ignores retain and release', () {
      final frame = RawFrame(
        format: RawFrameFormat.rgba,
        width: 1,
        height: 1,
        rotationDegrees: 0,
        timestampNs: 0,
        planes: [
          RawFramePlane(
            bytes: Uint8List.fromList([1, 2, 3, 4]),
            bytesPerRow: 4,
            bytesPerPixel: 4,
          ),
        ],
      );
      frame
        ..retain()
        ..release()
        ..release();
      expect(frame.isReleased, isFalse);
      expect(frame.planes.single.bytes, [1, 2, 3, 4]);
    });

    test('FrameSlot gives a slot back once', () {
      final slot = FrameSlot(arena, 3, 2);
      slot.free();
      slot.free();
      expect(arena.released, [(3, 2)]);
      expect(slot.isFreed, isTrue);
    });
  });

  group('sessions through the recorder', () {
    late _FakeSessionPlatform platform;
    const recorder = FlutterBackgroundVideoRecorder();

    setUp(() {
      platform = _FakeSessionPlatform();
      FlutterBackgroundVideoRecorderPlatform.instance = platform;
    });

    tearDown(() {
      FlutterBackgroundVideoRecorderPlatform.instance =
          MethodChannelFlutterBackgroundVideoRecorder();
    });

    test('a frame session delivers to several listeners', () async {
      final session = await recorder.openFrameSession(
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      expect(session.cameraId, '0');
      expect(session.width, 1280);

      final first = <int>[];
      final second = <int>[];
      session.frames.listen((f) => first.add(f.timestampNs));
      session.frames.listen((f) => second.add(f.timestampNs));
      platform.frames.add(_frame(1));
      platform.frames.add(_frame(2));
      await pumpEventQueue();

      expect(first, [1, 2]);
      expect(second, [1, 2]);
      await session.close();
    });

    test('the native side is only listened to while someone listens', () async {
      final session = await recorder.openFrameSession(
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      expect(platform.frames.hasListener, isFalse);

      final subscription = session.frames.listen((_) {});
      await pumpEventQueue();
      expect(platform.frames.hasListener, isTrue);

      await subscription.cancel();
      await pumpEventQueue();
      expect(platform.frames.hasListener, isFalse);
      await session.close();
    });

    test('close ends the stream, calls the platform once and may be '
        'repeated', () async {
      final session = await recorder.openFrameSession(
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      var done = false;
      session.frames.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();

      await session.close();
      await session.close();

      expect(done, isTrue);
      expect(platform.frameCloses, 1);
    });

    test('a failure reaches listeners as an error', () async {
      final session = await recorder.openFrameSession(
        cameraFacing: CameraFacing.rearCamera,
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      final errors = <Object>[];
      session.frames.listen((_) {}, onError: errors.add);
      await pumpEventQueue();

      platform.frames.addError(
        const RecorderException(RecorderErrorCode.cameraDisconnected),
      );
      await pumpEventQueue();

      expect(errors, hasLength(1));
      await session.close();
    });

    test('an audio stream delivers and closes the same way', () async {
      final session = await recorder.openAudioStream(
        notificationTitle: 'Title',
        notificationText: 'Text',
      );
      expect(session.sampleRate, 44100);

      final received = <int>[];
      var done = false;
      session.chunks.listen(
        (c) => received.add(c.timestampNs),
        onDone: () => done = true,
      );
      session.chunks.listen((_) {});
      platform.chunks.add(
        RawAudioChunk(
          bytes: Uint8List(4),
          sampleRate: 44100,
          channels: 1,
          encoding: RawAudioEncoding.pcm16,
          timestampNs: 7,
        ),
      );
      await pumpEventQueue();
      expect(received, [7]);

      await session.close();
      await session.close();
      expect(done, isTrue);
      expect(platform.audioCloses, 1);
    });
  });
}

RawFrame _frame(int timestamp) => RawFrame(
  format: RawFrameFormat.yuv420,
  width: 4,
  height: 2,
  rotationDegrees: 0,
  timestampNs: timestamp,
  planes: const [],
);

/// A frame in [memory], the way the platform delivers them: it holds the slot until released.
RawFrame _nativeFrame(
  FakeFrameMemory memory, {
  int slot = 0,
  int timestamp = 1,
}) => RawFrame.native(
  format: RawFrameFormat.yuv420,
  width: 4,
  height: 2,
  rotationDegrees: 0,
  timestampNs: timestamp,
  slot: FrameSlot(memory, 7, slot),
  planes: [
    RawFramePlane(
      bytes: memory.view(slot * 64, 4),
      bytesPerRow: 4,
      bytesPerPixel: 1,
    ),
  ],
);

class _FakeSessionPlatform extends FlutterBackgroundVideoRecorderPlatform
    with MockPlatformInterfaceMixin {
  // Synchronous, like the stream the platform really hands over: a frame is delivered, and given
  // back, before the next line of the test runs.
  final frames = StreamController<RawFrame>.broadcast(sync: true);
  final chunks = StreamController<RawAudioChunk>.broadcast();
  var frameCloses = 0;
  var audioCloses = 0;

  @override
  Future<RawFrameSessionInfo> openFrameSession({
    required CameraFacing cameraFacing,
    required String notificationTitle,
    required String notificationText,
    String? cameraId,
    RawFrameSettings settings = const RawFrameSettings(),
  }) async => RawFrameSessionInfo(
    cameraId: cameraId ?? '0',
    width: 1280,
    height: 720,
    format: settings.format,
  );

  @override
  Future<void> closeFrameSession() async => frameCloses++;

  @override
  Stream<RawFrame> get rawFrames => frames.stream;

  @override
  Future<RawAudioSessionInfo> openAudioStream({
    required String notificationTitle,
    required String notificationText,
    RawAudioSettings settings = const RawAudioSettings(),
  }) async => RawAudioSessionInfo(
    sampleRate: settings.sampleRate,
    channels: settings.channels,
    encoding: settings.encoding,
  );

  @override
  Future<void> closeAudioStream() async => audioCloses++;

  @override
  Stream<RawAudioChunk> get rawAudio => chunks.stream;
}
