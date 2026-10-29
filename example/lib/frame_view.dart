import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

/// The brightness plane of a YUV frame as a grey picture, four bytes (red, green, blue, alpha) a
/// pixel. A YUV frame is not something Flutter can paint, and the brightness alone shows the
/// picture, which is enough to see that the stream works.
Uint8List yPlaneToRgba(RawFrame frame) {
  final plane = frame.planes.first;
  final out = Uint8List(frame.width * frame.height * 4);
  var position = 0;
  for (var row = 0; row < frame.height; row++) {
    final start = row * plane.bytesPerRow;
    for (var column = 0; column < frame.width; column++) {
      final luma = plane.bytes[start + column * plane.bytesPerPixel];
      out[position++] = luma;
      out[position++] = luma;
      out[position++] = luma;
      out[position++] = 0xFF;
    }
  }
  return out;
}

/// Turns a frame of the stream into a picture Flutter can paint.
Future<ui.Image> decodeFrame(RawFrame frame) async {
  switch (frame.format) {
    case RawFrameFormat.jpeg:
      final codec = await ui.instantiateImageCodec(frame.planes.first.bytes);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    case RawFrameFormat.rgba:
      return _fromPixels(frame.planes.first.bytes, frame.width, frame.height);
    case RawFrameFormat.yuv420:
      return _fromPixels(yPlaneToRgba(frame), frame.width, frame.height);
  }
}

Future<ui.Image> _fromPixels(Uint8List pixels, int width, int height) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// Paints the newest frame of a stream, turned upright. Decoding one frame at a time, it skips
/// the frames that arrive meanwhile.
class FrameView extends StatefulWidget {
  const FrameView({super.key, required this.frame});

  final ValueListenable<RawFrame?> frame;

  @override
  State<FrameView> createState() => _FrameViewState();
}

class _FrameViewState extends State<FrameView> {
  ui.Image? _image;
  RawFrame? _shown;
  RawFrame? _pending;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    widget.frame.addListener(_onFrame);
    _onFrame();
  }

  @override
  void didUpdateWidget(FrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame != widget.frame) {
      oldWidget.frame.removeListener(_onFrame);
      widget.frame.addListener(_onFrame);
    }
  }

  @override
  void dispose() {
    widget.frame.removeListener(_onFrame);
    _pending?.release();
    _pending = null;
    _image?.dispose();
    super.dispose();
  }

  void _onFrame() {
    // A frame in native memory is only valid until it is released, and decoding takes a while, so
    // hold the one waiting to be decoded, and give back the one it replaces.
    final next = widget.frame.value?..retain();
    _pending?.release();
    _pending = next;
    if (next == null) {
      setState(() {
        _image?.dispose();
        _image = null;
        _shown = null;
      });
      return;
    }
    unawaited(_decodePending());
  }

  Future<void> _decodePending() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (_pending != null) {
        final frame = _pending!;
        _pending = null;
        final ui.Image image;
        try {
          image = await decodeFrame(frame);
        } finally {
          // Done with the pixels, whether or not they could be decoded.
          frame.release();
        }
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
          _shown = frame;
        });
      }
    } on Exception {
      // A frame that cannot be decoded is simply not shown.
    } finally {
      _decoding = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final frame = _shown;
    if (image == null || frame == null) return const SizedBox.shrink();
    final upright = frame.uprightSize;
    return AspectRatio(
      aspectRatio: upright.width / upright.height,
      child: RotatedBox(
        quarterTurns: (frame.rotationDegrees ~/ 90) % 4,
        child: SizedBox.expand(child: RawImage(image: image, fit: BoxFit.fill)),
      ),
    );
  }
}
