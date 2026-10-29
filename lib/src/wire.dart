// How the values of the platform channels are written on the wire, and how they are read back.
//
// The Android side sends plain maps, lists and strings; these functions turn them into the types of
// the package, so that the channel code itself only moves messages. Anything that is not what the
// native side promises throws, which the stream or call it arrived on reports as an error.
import 'dart:typed_data';

import 'models.dart';

/// The value of the `cameraFacing` argument.
String facingToWire(CameraFacing facing) => switch (facing) {
  CameraFacing.frontCamera => 'front',
  CameraFacing.rearCamera => 'rear',
};

// region Cameras and capabilities

/// One camera of the `listCameras` result.
CameraInfo cameraFromWire(Map<Object?, Object?> map) => CameraInfo(
  id: map['id'] as String,
  position: switch (map['position']) {
    'front' => CameraPosition.front,
    'external' => CameraPosition.external,
    _ => CameraPosition.rear,
  },
  sensorOrientation: (map['sensorOrientation'] as num?)?.toInt() ?? 0,
  zoomRange: zoomRangeFromWire(map),
  focalLengthMm: (map['focalLengthMm'] as num?)?.toDouble(),
  focalLengthEquivalentMm: (map['focalLengthEquivalentMm'] as num?)?.toDouble(),
  minimumFocusDistance: (map['minimumFocusDistance'] as num?)?.toDouble(),
  isLogicalMultiCamera: map['isLogicalMultiCamera'] == true,
  physicalCameraIds: [
    for (final id in (map['physicalCameraIds'] as List<Object?>? ?? const []))
      id as String,
  ],
);

/// The `zoomMin` and `zoomMax` entries of a map, or [ZoomRange.none] when they are missing.
ZoomRange zoomRangeFromWire(Map<Object?, Object?> map) {
  final min = (map['zoomMin'] as num?)?.toDouble();
  final max = (map['zoomMax'] as num?)?.toDouble();
  return min == null || max == null ? ZoomRange.none : ZoomRange(min, max);
}

/// The result of `getVideoCapabilities`.
VideoCapabilities capabilitiesFromWire(Map<Object?, Object?> map) {
  CodecSupport codec(Object? raw) {
    final entry = (raw as Map<Object?, Object?>?) ?? const {};
    return CodecSupport(
      supported: entry['supported'] == true,
      hardwareAccelerated: entry['hardware'] == true,
    );
  }

  final codecs = (map['codecs'] as Map<Object?, Object?>?) ?? const {};
  final recommended = map['recommended'] as Map<Object?, Object?>?;
  return VideoCapabilities(
    cameraId: map['cameraId'] as String?,
    zoomRange: zoomRangeFromWire(map),
    defaultResolution:
        recommended == null
            ? null
            : VideoResolution(
              recommended['width'] as int,
              recommended['height'] as int,
            ),
    defaultFrameRate: recommended?['frameRate'] as int?,
    modes: [
      for (final raw in (map['modes'] as List<Object?>? ?? const []))
        VideoMode(
          VideoResolution(
            (raw as Map<Object?, Object?>)['width'] as int,
            raw['height'] as int,
          ),
          List<int>.from(raw['frameRates'] as List<Object?>),
        ),
    ],
    h264: codec(codecs['h264']),
    hevc: codec(codecs['hevc']),
  );
}

// endregion

// region Recording and state

/// The answer of `startVideoRecording` and `startAudioRecording`.
StartRecordingResult startResultFromWire(String? result) => switch (result) {
  'started' => StartRecordingResult.started,
  'permissionDenied' => StartRecordingResult.permissionDenied,
  'permissionPermanentlyDenied' =>
    StartRecordingResult.permissionPermanentlyDenied,
  _ =>
    throw RecorderException(
      RecorderErrorCode.unknown,
      'Unexpected start result: $result',
    ),
};

/// Whether a saved recording is a video or sound only.
RecordedMediaKind mediaKindFromWire(Object? kind) =>
    kind == 'audio' ? RecordedMediaKind.audio : RecordedMediaKind.video;

/// The recorder state, as sent by `getRecordingStatus` and in state events.
RecorderStatus statusFromWire(String? status) => switch (status) {
  'initializing' => RecorderStatus.initializing,
  'recording' => RecorderStatus.recording,
  'stopped' => RecorderStatus.stopped,
  'error' => RecorderStatus.error,
  _ => RecorderStatus.notInitialized,
};

/// The picture of a preview, as sent by `startPreview` and in preview events.
PreviewInfo previewFromWire(Map<Object?, Object?> map) => PreviewInfo(
  textureId: (map['textureId'] as num).toInt(),
  width: map['width'] as int,
  height: map['height'] as int,
  active: map['active'] == true,
);

/// An event of the main event channel: a state change, a warning or a preview change.
RecorderEvent eventFromWire(dynamic event) {
  final map = event as Map<Object?, Object?>;
  if (map['type'] == 'preview') {
    return RecorderEvent.preview(previewFromWire(map));
  }
  if (map['type'] == 'warning') {
    return RecorderEvent.warning(
      RecorderWarning(
        RecorderWarningCode.fromWire(map['warningCode'] as String?),
        map['warningMessage'] as String?,
      ),
    );
  }
  final status = statusFromWire(map['status'] as String?);
  final errorCode = map['errorCode'] as String?;
  final mediaUri = map['mediaUri'] as String?;
  return RecorderEvent(
    status,
    errorCode == null
        ? null
        : RecorderException(
          RecorderErrorCode.fromWire(errorCode),
          map['errorMessage'] as String?,
          mediaUri == null
              ? null
              : RecordedMedia(
                uri: mediaUri,
                path: map['mediaPath'] as String?,
                kind: mediaKindFromWire(map['mediaKind']),
                hasLocation: map['mediaHasLocation'] == true,
              ),
        ),
  );
}

// endregion

// region Raw sessions

/// How the pixels of a frame are laid out.
RawFrameFormat frameFormatFromWire(Object? format) => switch (format) {
  'jpeg' => RawFrameFormat.jpeg,
  'rgba' => RawFrameFormat.rgba,
  _ => RawFrameFormat.yuv420,
};

/// A frame event of the frame channel, or null for the `closed` event that ends a session.
///
/// The pixels are not in the event: it names the native slot they were written to, and the frame
/// reads them in place from [memory].
RawFrame? frameFromWire(dynamic event, NativeFrameMemory memory) {
  final map = event as Map<Object?, Object?>;
  if (map['type'] == 'closed') return null;
  // The native side counted a reference for us when it sent the event; from here on the frame (or
  // its finalizer) owns it, and it is given back even if the event cannot be read.
  final slot = FrameSlot(
    memory,
    (map['ring'] as num).toInt(),
    map['slot'] as int,
  );
  try {
    final address = (map['address'] as num).toInt();
    return RawFrame.native(
      format: frameFormatFromWire(map['format']),
      width: map['width'] as int,
      height: map['height'] as int,
      rotationDegrees: map['rotation'] as int,
      timestampNs: (map['timestampNs'] as num).toInt(),
      droppedFrames: (map['dropped'] as num?)?.toInt() ?? 0,
      slot: slot,
      planes: [
        for (final raw in map['planes'] as List<Object?>)
          RawFramePlane(
            bytes: memory.view(
              address + ((raw as Map<Object?, Object?>)['offset'] as int),
              raw['length'] as int,
            ),
            bytesPerRow: raw['bytesPerRow'] as int,
            bytesPerPixel: raw['bytesPerPixel'] as int,
          ),
      ],
    );
  } catch (_) {
    slot.free();
    rethrow;
  }
}

/// How the samples of an audio chunk are stored.
RawAudioEncoding audioEncodingFromWire(Object? encoding) =>
    encoding == 'pcmFloat' ? RawAudioEncoding.pcmFloat : RawAudioEncoding.pcm16;

/// A chunk event of the audio channel, or null for the `closed` event that ends a stream.
RawAudioChunk? audioChunkFromWire(dynamic event) {
  final map = event as Map<Object?, Object?>;
  if (map['type'] == 'closed') return null;
  return RawAudioChunk(
    bytes: map['bytes'] as Uint8List,
    sampleRate: map['sampleRate'] as int,
    channels: map['channels'] as int,
    encoding: audioEncodingFromWire(map['encoding']),
    timestampNs: (map['timestampNs'] as num).toInt(),
  );
}

// endregion
