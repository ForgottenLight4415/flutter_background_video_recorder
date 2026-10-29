import 'dart:typed_data';

import 'native_frames.dart';
import 'session_stream.dart';
import 'video_settings.dart';

/// How the pixels of a [RawFrame] are laid out.
enum RawFrameFormat {
  /// The camera's own YUV 4:2:0 format (YUV_420_888): a brightness plane followed by two colour
  /// planes at half the size. It is the cheapest to produce and what most image-processing and
  /// machine-learning libraries accept; convert it to RGB if you need to show it.
  yuv420,

  /// One JPEG image per frame. Easy to show or upload, but costs CPU to compress and loses a
  /// little quality.
  jpeg,

  /// Four bytes per pixel, in the order red, green, blue, alpha, without gaps between rows.
  /// The easiest to use and four times as large as the brightness plane of [yuv420].
  rgba,
}

/// How to receive camera frames, for [FlutterBackgroundVideoRecorder.openFrameSession].
class RawFrameSettings {
  /// Settings for a frame session. Leave a field out to get its default.
  const RawFrameSettings({
    this.format = RawFrameFormat.yuv420,
    this.resolution,
    this.maxFrameRate,
    this.jpegQuality = 80,
    this.initialZoom = 1.0,
  });

  /// How the pixels are delivered. [RawFrameFormat.yuv420] unless you ask for something else.
  final RawFrameFormat format;

  /// The size of the frames before they are rotated upright. The camera must support it; the
  /// nearest supported size is used otherwise. Leave null for the largest size up to 720p with
  /// the camera's own aspect ratio.
  final VideoResolution? resolution;

  /// Deliver at most this many frames per second. Leave null for every frame the camera makes.
  final int? maxFrameRate;

  /// JPEG quality from 1 to 100, for [RawFrameFormat.jpeg].
  final int jpegQuality;

  /// The zoom ratio the session starts with, limited to what the camera supports. Change it later
  /// with [FlutterBackgroundVideoRecorder.setZoom].
  final double initialZoom;
}

/// One plane of a frame: a rectangle of bytes.
class RawFramePlane {
  /// A plane of [bytes] with [bytesPerRow] bytes per row and [bytesPerPixel] bytes from one pixel
  /// to the next.
  const RawFramePlane({
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });

  /// The plane's bytes. For a frame from a [RawFrameSession] this is a view of native memory, valid
  /// only as long as the frame is: see [RawFrame].
  final Uint8List bytes;

  /// The distance in bytes from the start of one row to the start of the next. It can be larger
  /// than the width of the plane times [bytesPerPixel]: rows may be padded.
  final int bytesPerRow;

  /// The distance in bytes from one pixel to the next in a row. For the colour planes of
  /// [RawFrameFormat.yuv420] it is often 2, because the two planes are interleaved.
  final int bytesPerPixel;
}

/// One picture from the camera.
///
/// **A frame from a [RawFrameSession] is valid only while it is being delivered.** Its pixels
/// stay in native memory, shared with the camera side, and are not copied for you: that is what
/// keeps large frames cheap. When the listeners of [RawFrameSession.frames] have all returned, the
/// memory is given back and reused for a later frame, so
///
/// * use [planes] inside the listener, and do not keep [RawFramePlane.bytes] past it, and
/// * to work on a frame later or elsewhere (after an `await`, in another isolate), call [retain]
///   first and [release] when done, or take a copy with [toOwned].
///
/// Reading [planes] after the frame was released throws a [StateError]. Frames you build yourself
/// with the constructor own their bytes and are always valid.
class RawFrame {
  /// A frame that owns its [planes], for example one made in a test.
  RawFrame({
    required this.format,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.timestampNs,
    required List<RawFramePlane> planes,
    this.droppedFrames = 0,
  }) : _planes = planes,
       _slot = null;

  /// A frame whose planes are views of native memory that [slot] keeps reserved. Used by platform
  /// implementations.
  RawFrame.native({
    required this.format,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.timestampNs,
    required List<RawFramePlane> planes,
    required FrameSlot slot,
    this.droppedFrames = 0,
  }) : _planes = planes,
       _slot = slot {
    // A frame that is retained and then forgotten must not keep its slot for ever.
    _finalizer.attach(this, slot, detach: this);
  }

  static final Finalizer<FrameSlot> _finalizer = Finalizer(
    (slot) => slot.free(),
  );

  /// How the pixels in [planes] are laid out.
  final RawFrameFormat format;

  /// The width of the picture in pixels, as it comes from the camera, so before it is rotated
  /// upright with [rotationDegrees].
  final int width;

  /// The height of the picture in pixels, before it is rotated upright.
  final int height;

  /// How many degrees clockwise (0, 90, 180 or 270) the picture must be turned to be upright for
  /// a user who holds the device as the screen is turned now.
  final int rotationDegrees;

  /// When the camera captured the frame, in nanoseconds on the camera's clock. Frames of one
  /// session can be compared with each other; the origin is not necessarily the same as for
  /// [RawAudioChunk.timestampNs], so do not subtract one from the other to line them up.
  final int timestampNs;

  /// How many frames the session has dropped so far because every slot was still in use, which
  /// happens when the app is not reading fast enough (or holds on to frames).
  final int droppedFrames;

  final List<RawFramePlane> _planes;
  final FrameSlot? _slot;
  int _holds = 1;
  bool _deliveryEnded = false;

  /// The pixels. [RawFrameFormat.yuv420] has three planes (Y, U and V); the others have one.
  ///
  /// Throws a [StateError] once the frame was released. See the class description.
  List<RawFramePlane> get planes {
    if (isReleased) {
      throw StateError(
        'This RawFrame was released: its pixels may already belong to a later frame. '
        'Call retain() before the listener returns to keep a frame, or use toOwned().',
      );
    }
    return _planes;
  }

  /// The frame's size after [rotationDegrees] is applied.
  ({int width, int height}) get uprightSize =>
      rotationDegrees % 180 == 0
          ? (width: width, height: height)
          : (width: height, height: width);

  /// Whether the frame's memory was given back. Always false for a frame that owns its bytes.
  bool get isReleased => _slot != null && _holds == 0;

  /// Keeps the frame valid after the listener returns, until a matching [release]. Call it inside
  /// the listener. Does nothing for a frame that owns its bytes.
  ///
  /// A frame the app holds cannot be reused for new pictures. When all the slots are held, new
  /// frames are dropped (see [droppedFrames]), so release frames promptly.
  void retain() {
    if (_slot == null) return;
    if (_holds == 0) {
      throw StateError(
        'This RawFrame was already released and cannot be retained.',
      );
    }
    _holds++;
  }

  /// Gives back a hold taken with [retain]. When none is left the memory is reused. Does nothing
  /// if the frame is already released, or owns its bytes.
  void release() {
    final slot = _slot;
    if (slot == null || _holds == 0) return;
    _holds--;
    if (_holds == 0) {
      _finalizer.detach(this);
      slot.free();
    }
  }

  /// A copy of the frame in ordinary memory, valid for ever and not holding any slot. Costs one
  /// copy of the pixels, so prefer reading in place where you can.
  RawFrame toOwned() => RawFrame(
    format: format,
    width: width,
    height: height,
    rotationDegrees: rotationDegrees,
    timestampNs: timestampNs,
    droppedFrames: droppedFrames,
    planes: [
      for (final plane in planes)
        RawFramePlane(
          bytes: Uint8List.fromList(plane.bytes),
          bytesPerRow: plane.bytesPerRow,
          bytesPerPixel: plane.bytesPerPixel,
        ),
    ],
  );

  // The session calls this when every listener has seen the frame: the delivery's own hold ends.
  void _endDelivery() {
    if (_deliveryEnded) return;
    _deliveryEnded = true;
    release();
  }
}

/// What a frame session came up with when it opened.
class RawFrameSessionInfo {
  /// Describes an open frame session.
  const RawFrameSessionInfo({
    required this.cameraId,
    required this.width,
    required this.height,
    required this.format,
  });

  /// The camera in use, see [CameraInfo.id].
  final String cameraId;

  /// The width of the frames, before they are rotated upright.
  final int width;

  /// The height of the frames, before they are rotated upright.
  final int height;

  /// How the frames are delivered.
  final RawFrameFormat format;
}

/// An open camera that delivers [frames] until [close] is called.
///
/// It keeps running while the app is in the background, with a notification, and it is
/// independent of recording: no recording needs to be started. Open one with
/// [FlutterBackgroundVideoRecorder.openFrameSession].
///
/// [frames] can be listened to by any number of listeners at the same time. While nobody listens,
/// the camera keeps running but no frames are prepared. A failure such as a lost camera arrives as
/// a [RecorderException] on [frames], after which the session is over.
///
/// Frames are delivered synchronously and are only valid during delivery; see [RawFrame].
class RawFrameSession {
  /// A session described by [info], delivering what [frames] carries. Created by
  /// [FlutterBackgroundVideoRecorder.openFrameSession]; [onClose] ends the session natively.
  RawFrameSession({
    required RawFrameSessionInfo info,
    required Stream<RawFrame> frames,
    required Future<void> Function() onClose,
  }) : cameraId = info.cameraId,
       width = info.width,
       height = info.height,
       format = info.format,
       _stream = SessionStream<RawFrame>(
         frames,
         onClose,
         onDispatched: (frame) => frame._endDelivery(),
       );

  /// The camera in use, see [CameraInfo.id].
  final String cameraId;

  /// The width of the frames, before they are rotated upright.
  final int width;

  /// The height of the frames, before they are rotated upright.
  final int height;

  /// How the frames are delivered.
  final RawFrameFormat format;

  final SessionStream<RawFrame> _stream;

  /// The frames. A broadcast stream that completes when the session is closed.
  Stream<RawFrame> get frames => _stream.stream;

  /// Closes the camera and removes the notification. Safe to call more than once.
  Future<void> close() => _stream.close();
}
