# Flutter Background Video Recorder

A Flutter plugin for Android that records video or audio from a foreground service, so recording
continues while the app is in the background, closed, or the screen is off or locked.

* Android 12 (API 31) up to Android 17 (API 37)
* **Video** with the front or rear camera. Pick the size, aspect ratio and frame rate from what the
  device really supports (default 1080p at 60 fps), and the codec (H.264, or HEVC for smaller files)
* **Audio only** recordings that use only the microphone
* **Live preview** in your app, before and during a recording. Hiding it is just removing a widget
* Optional **location** stored in the video's metadata
* Recordings are saved with `MediaStore` (videos in `Movies/<folder>`, audio in
  `Recordings/<folder>`) and show up in the gallery and audio apps
* A notification (required by Android) is shown while recording, with a Stop button
* If something goes wrong mid-recording (camera taken, disk full, device overheating) what was
  recorded is saved and the user is told
* Not available on iOS

## Usage

```dart
import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart';

final recorder = FlutterBackgroundVideoRecorder();

// Follow the state of the recorder.
recorder.recorderState.listen((status) => print(status)); // initializing, recording, stopped, error
recorder.recorderErrors.listen((error) => print(error));  // e.g. the camera was taken by another app
recorder.recorderWarnings.listen((warning) => print(warning)); // e.g. the device is getting hot

// Starts recording. Asks for permissions first if they are missing.
final result = await recorder.startVideoRecording(
  folderName: 'My Videos',
  cameraFacing: CameraFacing.rearCamera,
  notificationTitle: 'Recording video',
  notificationText: 'Tap to return to the app',
);
switch (result) {
  case StartRecordingResult.started:
    break;
  case StartRecordingResult.permissionDenied:
    // The user said no. Explain why you need it; starting again asks again.
    break;
  case StartRecordingResult.permissionPermanentlyDenied:
    // Android will not show the dialog any more. Explain, then send the user to the settings.
    await recorder.openAppSettings();
}

// Stops recording and returns what was saved.
final media = await recorder.stopRecording();
print(media.uri);  // content://media/external/video/media/... (use this one)
print(media.path); // /storage/emulated/0/Movies/My Videos/... (best effort, may be null)
```

`startVideoRecording` and `stopRecording` throw a `RecorderException` with a `RecorderErrorCode`
when they fail, for example `alreadyRecording` or `notRecording`. When the app starts, call
`getRecordingStatus()` to find out whether a recording from an earlier session is still running.

See the [example](example) for a complete app.

## Size, frame rate and codec

Ask the device what it can do, then choose from that:

```dart
final capabilities = await recorder.getVideoCapabilities(CameraFacing.rearCamera);

capabilities.byAspectRatio;        // {'16:9': [1920x1080, 1280x720, ...], '4:3': [...]}
capabilities.modes.first.frameRates; // [24, 30, 60]
capabilities.defaultResolution;    // what a recording uses if you set nothing, e.g. 1920x1080
capabilities.defaultFrameRate;     // e.g. 60
capabilities.modes.first.resolution.portraitAspectRatioLabel; // '9:16', for a '16:9' size
capabilities.hevc.supported;       // can this device encode HEVC?
capabilities.hevc.hardwareAccelerated; // and is it cheap on battery and heat?

await recorder.startVideoRecording(
  folderName: 'My Videos',
  cameraFacing: CameraFacing.rearCamera,
  notificationTitle: 'Recording video',
  notificationText: 'Tap to return to the app',
  settings: const VideoSettings(
    resolution: VideoResolution(1920, 1080),
    frameRate: 30,
    codec: VideoCodec.hevc,
  ),
);
```

* With no settings the recorder uses **1080p at 60 fps**, falling back to 1080p at 30 fps and then the
  best size up to 1080p when the camera cannot do that. `defaultResolution` and `defaultFrameRate`
  tell you which of these it will be on this camera, so a settings screen can show real values
  instead of a vague "default".
* Videos are stored landscape and rotated on playback, so a `16:9` size is a `9:16` video when the
  phone is held upright; show both if that helps your users.
* Anything you set must be supported, otherwise starting throws
  `RecorderErrorCode.unsupportedConfiguration` with the reason. A recording is never silently
  different from what you asked for.
* `VideoCodec.h264` (default) plays everywhere. `VideoCodec.hevc` makes files roughly 40% smaller but
  some players and upload services handle it poorly. `VideoCodec.auto` uses HEVC only when the device
  has a hardware encoder.
* The bitrate suits the device, size, frame rate and codec; set `VideoSettings.bitrate` to override.
* Frame rates above 60 (slow motion) are not supported.

## Audio only

```dart
await recorder.startAudioRecording(
  folderName: 'My Notes',
  notificationTitle: 'Recording audio',
  notificationText: 'Tap to return to the app',
);
final audio = await recorder.stopRecording(); // audio.kind == RecordedMediaKind.audio
```

It needs only the microphone permission (not the camera one), the camera is never opened, and Android
shows only the microphone privacy indicator. Audio is saved as AAC (`.m4a`, 48 kHz, 128 kbps) in
`Recordings/<folder>`.

## Location in the video

```dart
settings: const VideoSettings(embedLocation: true)
```

The position when recording started is stored in the video's metadata (`RecordedMedia.hasLocation`
tells whether that worked). It is **opt-in on purpose**: the plugin declares no location permission,
so apps that never use this feature do not ship with one. To use it, add this to **your app's**
`AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

Without it, starting throws `RecorderErrorCode.locationPermissionNotDeclared`. The permission is
asked for together with the others and is optional: if the user denies it, or no position is found
within a few seconds, the video is recorded without one.

## Preview

```dart
// Before recording it is a viewfinder; during a recording it shows the live picture.
RecorderPreview(
  cameraFacing: CameraFacing.rearCamera,
  resolution: selectedResolution, // so it has the same shape as the video
)
```

To keep the picture available while recording, start with `VideoSettings(preview: true)`.

**Hiding the preview is removing the `RecorderPreview` widget**, for example
`if (showPreview) RecorderPreview(...)`. The recording is not affected, and adding the widget again
brings the live picture back. When nothing is being recorded, removing it also releases the camera.

Things to know:

* Android fixes the camera's outputs when a recording starts, so a preview can only be shown during a
  recording that was started with `preview: true`. Without it, `RecorderPreview` shows its
  `placeholder` during the recording.
* A preview during recording costs a little GPU work. On a device that cannot deliver a second
  stream next to the recording, the recording goes ahead without a preview and
  `RecorderWarningCode.previewUnavailable` is reported.
* The widget sizes itself to the picture's aspect ratio (upright, whichever way the device is held),
  and mirrors the front camera like a mirror unless `mirrorFront: false`. The recorded video is
  never mirrored.
* The viewfinder asks for the camera permission if it is missing. When the app goes to the
  background it stops, and it starts again on return.

## Setup

Nothing to add to your `AndroidManifest.xml` (except for [location](#location-in-the-video), if you
use it): the permissions and the recording service are merged in from the plugin. You need `minSdk 31`
or higher and Flutter 3.29 or newer.

| Permission | Why |
| --- | --- |
| `CAMERA`, `RECORD_AUDIO` | Required for video. Audio-only needs just `RECORD_AUDIO`. Requested when recording starts. |
| `POST_NOTIFICATIONS` | Android 13+. Requested with the others. Recording still works if it is denied, but the notification (and its Stop button) is hidden. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CAMERA`, `FOREGROUND_SERVICE_MICROPHONE` | Install-time permissions for the recording service. |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | Only if you use `embedLocation`, and then declared by **you**. |

## Blocked permissions

Android stops showing the permission dialog once the user has denied it twice. From then on
`startVideoRecording` returns `StartRecordingResult.permissionPermanentlyDenied` immediately, and
the only way forward is the system settings. The plugin does not show any UI of its own: explain to
the user why the camera and microphone are needed, then call `openAppSettings()` to open your app's
settings page. Permissions are checked again on every `startVideoRecording`, so recording works as
soon as the user comes back with them granted. The example app shows a dialog that does this.

## If the camera is lost while recording

Another app can take the camera (for example when the user opens the camera app), and it can be
disconnected or fail. The recording then ends and **the video recorded up to that point is saved**.

* Android shows a "Recording stopped" notification explaining what happened, so the user knows even
  if your app is closed. Tapping it opens your app. It is only shown if notifications are allowed.
* While your app is alive, `recorderState` emits `RecorderStatus.error` and `recorderErrors` emits a
  `RecorderException` (`cameraDisconnected` or `cameraError`) whose `savedMedia` is the saved video.
* You can start a new recording afterwards.

The notification text can be changed by overriding the `fbvr_alert_*` string resources in your app.

## Things to know

* **Start recording while your app is visible.** Android 11+ does not let an app that is in the
  background open the camera or microphone, and Android 12+ does not let it start a foreground
  service. Once recording has started, it keeps going in the background. Starting from the background
  is refused by Android and surfaces as a `RecorderException` (typically
  `RecorderErrorCode.foregroundServiceNotAllowed`).
* Recording is owned by the service, not the Activity. It survives the app being swiped away as long
  as Android keeps the process alive, which it does while the foreground service runs.
* Android shows its camera/microphone privacy indicators while recording. This cannot be disabled.
* Only one recording at a time is supported.
* **Recording while the phone is in a pocket or the screen is off works**, but Android limits what a
  background app may *start*: begin the recording while your app is visible.
* If the device runs low on storage the recording stops cleanly with what was recorded so far
  (`RecorderErrorCode.storageFull`); if it overheats badly it does the same
  (`RecorderErrorCode.thermalShutdown`), after a `thermalWarning` first.

## Migrating from 1.x

| 1.x | 2.0 |
| --- | --- |
| `<service android:name="services.VideoRecorderService" .../>` in your manifest | **Remove it.** The plugin declares its own service. |
| `import '.../flutter_bvr.dart'` and `'.../flutter_bvr_platform_interface.dart'` | `import 'package:flutter_background_video_recorder/flutter_background_video_recorder.dart'` |
| `startVideoRecording(...) -> Future<bool?>` (`false` meant "asking for permissions") | Returns `StartRecordingResult` after the permission dialogs are answered |
| `stopVideoRecording() -> Future<String?>` (file path) | `stopRecording()` returns `RecordedMedia` (`uri`, optional `path`); `stopVideoRecording()` still works as an alias |
| `recorderState` and `getVideoRecordingStatus()` returned `int` | `RecorderStatus` enum, `getRecordingStatus()` |
| `showToast` | Removed. Toasts do not work from the background on modern Android; react to `recorderState` instead. |
| Failures were reported as `PlatformException`s with numeric codes | `RecorderException` with a `RecorderErrorCode` |
| Supported Android 9 and up, Flutter 2.5 and up | Requires Android 12 (`minSdk 31`) and Flutter 3.29 |

## Contributing

Contributions are welcome, including an iOS implementation.
