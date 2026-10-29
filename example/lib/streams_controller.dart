import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

import 'recorder_controller.dart';

/// One subscription to a stream, with its own count. The cards of the Streams panel show every
/// listener, to make visible that any number of them can read the same session.
class StreamListener {
  StreamListener(this.id);

  final int id;

  /// How many items this listener has received.
  int received = 0;

  StreamSubscription<Object?>? subscription;
}

/// The open session of one raw stream and the listeners reading it.
///
/// The first listener opens the session and the last one to leave closes it. Every listener is a
/// separate subscription to the same broadcast stream.
class RawFeed<T> {
  RawFeed({
    required this.bytesOf,
    required this.onChanged,
    required this.onError,
    this.retain,
    this.releaseItem,
    this.droppedOf,
  });

  /// The size of one item, for the data rate.
  final int Function(T item) bytesOf;

  /// Keeps an item valid after delivery, and lets go of it. A frame in native memory is only valid
  /// while it is delivered, so the one shown on the stage is retained until the next replaces it.
  final void Function(T item)? retain;
  final void Function(T item)? releaseItem;

  /// How many items the session has dropped so far, if the item says.
  final int Function(T item)? droppedOf;
  final VoidCallback onChanged;

  /// Called with the failure that ended the session.
  final void Function(RecorderException error) onError;

  final listeners = <StreamListener>[];

  /// The newest item, for the stage.
  final latest = ValueNotifier<T?>(null);

  bool opening = false;
  Stream<T>? _stream;
  Future<void> Function()? _close;
  var _nextId = 1;

  /// Items received in total, and per second as of the last [tick].
  int total = 0;

  /// Items the session dropped because the app was not taking them fast enough.
  int dropped = 0;
  double perSecond = 0;
  double bytesPerSecond = 0;
  int _tickItems = 0;
  int _tickBytes = 0;

  /// The session is open or opening.
  bool get isOpen => _stream != null || opening;

  /// Opens the session with [open] if it is not open and adds a listener.
  Future<void> addListener(
    Future<({Stream<T> stream, Future<void> Function() close})> Function() open,
  ) async {
    if (opening) return;
    if (_stream == null) {
      opening = true;
      onChanged();
      try {
        final session = await open();
        _stream = session.stream;
        _close = session.close;
      } finally {
        opening = false;
        onChanged();
      }
    }
    _attach();
    onChanged();
  }

  void _attach() {
    final listener = StreamListener(_nextId++);
    listeners.add(listener);
    listener.subscription = _stream!.listen(
      (item) {
        listener.received++;
        // Count the session once, however many listeners read it.
        if (identical(listener, listeners.first)) {
          total++;
          _tickItems++;
          _tickBytes += bytesOf(item);
          dropped = droppedOf?.call(item) ?? 0;
          retain?.call(item);
          final previous = latest.value;
          latest.value = item;
          if (previous != null) releaseItem?.call(previous);
        }
        onChanged();
      },
      onError: (Object error) {
        if (error is RecorderException) onError(error);
        unawaited(_finish());
      },
      onDone: () => unawaited(_finish()),
    );
  }

  /// Removes the newest listener; the last one takes the session with it.
  Future<void> removeListener() async {
    if (listeners.length <= 1) {
      await close();
      return;
    }
    unawaited(listeners.removeLast().subscription?.cancel());
    onChanged();
  }

  /// Closes the session for everyone.
  Future<void> close() async {
    final closing = _close;
    await _finish();
    await closing?.call();
  }

  Future<void> _finish() async {
    final subscriptions = [for (final l in listeners) l.subscription];
    listeners.clear();
    _stream = null;
    _close = null;
    final shown = latest.value;
    latest.value = null;
    if (shown != null) releaseItem?.call(shown);
    total = 0;
    dropped = 0;
    perSecond = 0;
    bytesPerSecond = 0;
    _tickItems = 0;
    _tickBytes = 0;
    // Nobody needs to wait for a subscription to finish cancelling.
    for (final subscription in subscriptions) {
      unawaited(subscription?.cancel());
    }
    onChanged();
  }

  /// Updates the rates from what arrived in the last [interval].
  void tick(Duration interval) {
    final seconds = interval.inMicroseconds / Duration.microsecondsPerSecond;
    perSecond = _tickItems / seconds;
    bytesPerSecond = _tickBytes / seconds;
    _tickItems = 0;
    _tickBytes = 0;
  }

  void dispose() {
    unawaited(close());
    latest.dispose();
  }
}

/// The state of the Streams mode: the frame session and the audio stream, each with its listeners.
class StreamsController extends ChangeNotifier {
  StreamsController(this.recorder, this._source) {
    frames = RawFeed<RawFrame>(
      bytesOf:
          (frame) => [
            for (final p in frame.planes) p.bytes.length,
          ].fold(0, (a, b) => a + b),
      onChanged: _changed,
      onError: _fail,
      retain: (frame) => frame.retain(),
      releaseItem: (frame) => frame.release(),
      droppedOf: (frame) => frame.droppedFrames,
    );
    audio = RawFeed<RawAudioChunk>(
      bytesOf: (chunk) => chunk.bytes.length,
      onChanged: _changed,
      onError: _fail,
    );
    final interval = _source.tickInterval;
    if (interval != null) {
      _clock = Timer.periodic(interval, (_) {
        frames.tick(interval);
        audio.tick(interval);
        if (anyOpen) notifyListeners();
      });
    }
  }

  final FlutterBackgroundVideoRecorder recorder;
  final RecorderController _source;
  Timer? _clock;
  Timer? _throttle;
  bool _disposed = false;

  late final RawFeed<RawFrame> frames;
  late final RawFeed<RawAudioChunk> audio;

  /// How the next frame session delivers its pixels. Fixed while a session is open.
  RawFrameFormat frameFormat = RawFrameFormat.yuv420;

  /// The loudness of the latest audio chunk, from 0 to 1.
  final audioLevel = ValueNotifier<double>(0);

  bool get frameOpen => frames.isOpen;
  bool get audioOpen => audio.isOpen;
  bool get anyOpen => frameOpen || audioOpen;

  /// The size and format of the session that is open, for the stage badge.
  ({int width, int height, RawFrameFormat format})? frameInfo;

  /// The sample rate and channels of the audio stream that is open.
  ({int sampleRate, int channels})? audioInfo;

  void setFrameFormat(RawFrameFormat value) {
    if (frameOpen) return;
    frameFormat = value;
    notifyListeners();
  }

  // region Video frames

  Future<void> addFrameListener() => frames
      .addListener(() async {
        final session = await recorder.openFrameSession(
          cameraFacing: _source.facing,
          cameraId: _source.selectedCamera?.id,
          notificationTitle: 'Streaming camera frames',
          notificationText: 'Tap to return to the app',
          settings: RawFrameSettings(
            format: frameFormat,
            initialZoom: _source.zoom,
          ),
        );
        frameInfo = (
          width: session.width,
          height: session.height,
          format: session.format,
        );
        return (stream: session.frames, close: session.close);
      })
      .onError<RecorderException>((e, _) => _fail(e));

  Future<void> removeFrameListener() => frames.removeListener();

  /// The Subscribe switch: one listener on, or every listener off and the session closed.
  Future<void> setFrameSubscribed(bool on) =>
      on
          ? (frameOpen ? Future<void>.value() : addFrameListener())
          : frames.close();

  // endregion

  // region Audio

  Future<void> addAudioListener() => audio
      .addListener(() async {
        final session = await recorder.openAudioStream(
          notificationTitle: 'Streaming microphone',
          notificationText: 'Tap to return to the app',
        );
        audioInfo = (
          sampleRate: session.sampleRate,
          channels: session.channels,
        );
        return (stream: session.chunks.map(_measure), close: session.close);
      })
      .onError<RecorderException>((e, _) => _fail(e));

  Future<void> removeAudioListener() => audio.removeListener();

  Future<void> setAudioSubscribed(bool on) =>
      on
          ? (audioOpen ? Future<void>.value() : addAudioListener())
          : audio.close();

  RawAudioChunk _measure(RawAudioChunk chunk) {
    audioLevel.value = chunkLevel(chunk);
    return chunk;
  }

  // endregion

  /// Closes both sessions, for example when the user leaves Streams mode.
  Future<void> closeAll() async {
    await frames.close();
    await audio.close();
    audioLevel.value = 0;
  }

  void _fail(RecorderException error) {
    if (error.code == RecorderErrorCode.permissionPermanentlyDenied) {
      _source.say(UiMessageKind.permissionBlocked, 'Permissions are blocked.');
    } else {
      _source.say(UiMessageKind.error, RecorderController.describe(error));
    }
  }

  // Events can come many times a second; the screen shows them a few times a second.
  void _changed() {
    if (_disposed) return;
    if (_source.tickInterval == null) {
      notifyListeners();
      return;
    }
    _throttle ??= Timer(const Duration(milliseconds: 250), () {
      _throttle = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _clock?.cancel();
    _throttle?.cancel();
    frames.dispose();
    audio.dispose();
    audioLevel.dispose();
    super.dispose();
  }
}

/// How loud a chunk is, from 0 to 1: the root mean square of (up to a few hundred of) its samples,
/// curved so that ordinary speech is clearly visible on a meter.
double chunkLevel(RawAudioChunk chunk) {
  final data = chunk.bytes.buffer.asByteData(
    chunk.bytes.offsetInBytes,
    chunk.bytes.lengthInBytes,
  );
  final count = chunk.bytes.lengthInBytes ~/ chunk.bytesPerSample;
  if (count == 0) return 0;
  final step = count > 400 ? count ~/ 400 : 1;
  var sum = 0.0;
  var used = 0;
  for (var i = 0; i < count; i += step) {
    final sample =
        chunk.encoding == RawAudioEncoding.pcm16
            ? data.getInt16(i * 2, Endian.little) / 32768
            : data.getFloat32(i * 4, Endian.little);
    sum += sample * sample;
    used++;
  }
  final rms = math.sqrt(sum / used);
  return math.sqrt(rms).clamp(0.0, 1.0);
}
