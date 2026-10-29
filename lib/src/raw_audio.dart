import 'dart:typed_data';

import 'session_stream.dart';

/// How the samples of a [RawAudioChunk] are stored.
enum RawAudioEncoding {
  /// 16-bit signed integers, little endian. The default and what most audio code expects.
  pcm16,

  /// 32-bit floating point numbers from -1 to 1, little endian.
  pcmFloat,
}

/// Which microphone processing to ask for.
enum RawAudioSource {
  /// The normal microphone.
  mic,

  /// A microphone tuned for speech recognition.
  voiceRecognition,

  /// The microphone without noise suppression, gain control or other processing, when the device
  /// has one. Falls back to the normal microphone otherwise.
  unprocessed,
}

/// How to receive audio, for [FlutterBackgroundVideoRecorder.openAudioStream].
class RawAudioSettings {
  /// Settings for an audio stream. Leave a field out to get its default.
  const RawAudioSettings({
    this.sampleRate = 44100,
    this.channels = 1,
    this.encoding = RawAudioEncoding.pcm16,
    this.source = RawAudioSource.mic,
    this.chunkDuration = const Duration(milliseconds: 20),
  });

  /// Samples per second per channel. 44100 and 48000 work on every device; others may be refused
  /// with [RecorderErrorCode.unsupportedConfiguration].
  final int sampleRate;

  /// 1 for mono or 2 for stereo.
  final int channels;

  /// How the samples are stored.
  final RawAudioEncoding encoding;

  /// Which microphone processing to use.
  final RawAudioSource source;

  /// How much sound one [RawAudioChunk] carries. Shorter chunks mean less delay and more events.
  final Duration chunkDuration;
}

/// A short piece of sound.
class RawAudioChunk {
  /// A chunk of [bytes] recorded at [sampleRate].
  const RawAudioChunk({
    required this.bytes,
    required this.sampleRate,
    required this.channels,
    required this.encoding,
    required this.timestampNs,
  });

  /// The samples, interleaved by channel (left, right, left, right, ...), little endian, in the
  /// [encoding].
  final Uint8List bytes;

  /// Samples per second per channel.
  final int sampleRate;

  /// 1 for mono or 2 for stereo.
  final int channels;

  /// How the samples in [bytes] are stored.
  final RawAudioEncoding encoding;

  /// When the chunk was captured, in nanoseconds on the device's clock since boot. Chunks of one
  /// stream can be compared with each other; the origin is not necessarily the same as for
  /// [RawFrame.timestampNs], so do not subtract one from the other to line them up.
  final int timestampNs;

  /// The number of bytes of one sample of one channel.
  int get bytesPerSample => encoding == RawAudioEncoding.pcm16 ? 2 : 4;

  /// The number of sample frames (one sample per channel) in the chunk.
  int get frameCount => bytes.length ~/ (bytesPerSample * channels);

  /// The length of the chunk.
  Duration get duration =>
      Duration(microseconds: frameCount * 1000000 ~/ sampleRate);
}

/// What an audio stream came up with when it opened.
class RawAudioSessionInfo {
  /// Describes an open audio stream.
  const RawAudioSessionInfo({
    required this.sampleRate,
    required this.channels,
    required this.encoding,
  });

  /// Samples per second per channel.
  final int sampleRate;

  /// 1 for mono or 2 for stereo.
  final int channels;

  /// How the samples are stored.
  final RawAudioEncoding encoding;
}

/// An open microphone that delivers [chunks] until [close] is called.
///
/// It keeps running while the app is in the background, with a notification, and it is
/// independent of recording. Open one with [FlutterBackgroundVideoRecorder.openAudioStream].
///
/// [chunks] can be listened to by any number of listeners at the same time. While nobody listens,
/// the microphone keeps running but the sound is dropped. If the app falls behind, old chunks are
/// dropped and a [RecorderWarningCode.audioOverrun] is reported.
class RawAudioSession {
  /// A session described by [info], delivering what [chunks] carries. Created by
  /// [FlutterBackgroundVideoRecorder.openAudioStream]; [onClose] ends the stream natively.
  RawAudioSession({
    required RawAudioSessionInfo info,
    required Stream<RawAudioChunk> chunks,
    required Future<void> Function() onClose,
  }) : sampleRate = info.sampleRate,
       channels = info.channels,
       encoding = info.encoding,
       _stream = SessionStream<RawAudioChunk>(chunks, onClose);

  /// Samples per second per channel.
  final int sampleRate;

  /// 1 for mono or 2 for stereo.
  final int channels;

  /// How the samples are stored.
  final RawAudioEncoding encoding;

  final SessionStream<RawAudioChunk> _stream;

  /// The sound. A broadcast stream that completes when the session is closed.
  Stream<RawAudioChunk> get chunks => _stream.stream;

  /// Closes the microphone and removes the notification. Safe to call more than once.
  Future<void> close() => _stream.close();
}
