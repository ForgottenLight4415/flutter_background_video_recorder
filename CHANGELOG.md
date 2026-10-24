## 2.0.0
Modernized for Android 15 and 16. **Breaking changes**, see "Migrating from 1.x" in the README.

### Breaking
* Requires Android 12 (`minSdk 31`) and Flutter 3.29+. Older Android versions are no longer supported.
* Requires Dart 3.5+. The previous constraint (`<3.0.0`) prevented the package from resolving on any current Flutter.
* The recording service is now declared by the plugin and lives at
  `com.lightsoftware.flutter_background_video_recorder.plugin.VideoRecorderService`. Remove the `services.VideoRecorderService` entry from your app manifest.
* `startVideoRecording` returns `StartRecordingResult`, and resolves after the permission dialogs are answered.
* `stopRecording` (and its alias `stopVideoRecording`) returns `RecordedMedia` (`uri`, optional `path`, `kind`, `hasLocation`) instead of a file path.
* States are the `RecorderStatus` enum instead of integers. Errors are `RecorderException`s. `getVideoRecordingStatus` is now `getRecordingStatus`.
* Removed the `showToast` parameter and all native toasts.
* New barrel library `package:flutter_background_video_recorder/flutter_background_video_recorder.dart`.

### Fixed
* **Audio was recorded at 8 kHz and about 12 kbps** (the platform default when nothing is set). It is now 48 kHz, 128 kbps AAC.
* A `MediaRecorder` error (full disk, encoder failure) used to leave the recorder stuck in "recording". Errors now end the recording cleanly and keep what was recorded; running out of storage and overheating are reported as such.
* The recorder refuses to start with almost no free storage and caps the file size so the disk is not filled completely.
* The foreground service now declares both camera and microphone types. Before, only the microphone type was used, so the camera was cut off in the background on Android 14+.
* `POST_NOTIFICATIONS` is declared and requested (Android 13+).
* Videos are saved through `MediaStore` (scoped storage) instead of raw paths in public storage.
* The permission flow no longer races, crashes on partial results or swallows other plugins' permission results.
* Recorder state no longer travels over exported broadcasts that other apps could spoof or read.
* `MediaRecorder` starts only once the capture session is configured, uses `TEMPLATE_RECORD`, is stopped and released correctly, and a failed or empty recording is discarded.
* The service no longer crashes when restarted by the system with a null intent, and recording no longer depends on the Activity being bound.
* Video resolution selection (operator precedence bug, arbitrary fallback) and orientation for rear/front cameras.
* Removed unused `SYSTEM_ALERT_WINDOW` and `READ_EXTERNAL_STORAGE` permissions and a duplicate `CAMERA` declaration.

### Added
* **Video settings:** `getVideoCapabilities()` lists the sizes (grouped by aspect ratio), frame rates and codecs a camera supports. `VideoSettings` chooses resolution, frame rate, codec (`h264`, `hevc`, `auto`) and bitrate. The default is 1080p at 60 fps with fallbacks; an unsupported choice is refused with `unsupportedConfiguration`.
* **Audio-only** recordings with `startAudioRecording()`: microphone permission and foreground type only, saved to `Recordings/<folder>`.
* **Location** in the video's metadata with `VideoSettings(embedLocation: true)`. The plugin declares no location permission; the app does.
* **Preview:** the `RecorderPreview` widget shows a viewfinder before recording and the live picture during a recording started with `VideoSettings(preview: true)`. Hiding it is removing the widget. Front camera preview is mirrored like a mirror.
* `VideoCapabilities.defaultResolution` / `defaultFrameRate` (what a recording uses when nothing is set) and `VideoResolution.portraitAspectRatioLabel` (`9:16` for `16:9`).
* The example app is now a camera-style viewfinder: full-screen preview, record button with a live timer, Video / Audio modes, a settings sheet with aspect ratio (with its vertical equivalent), resolution, frame rate and codec, and a landscape layout.
* `recorderWarnings` stream (`thermalWarning`, `previewUnavailable`).
* `openAppSettings()` to send the user to the system settings when permissions are permanently denied, and a dialog in the example that does so.
* When the camera is lost mid-recording, the video recorded so far is saved, a "Recording stopped" notification is shown, and `RecorderException.savedMedia` points to the saved video.
* A Stop action, content intent, own icon and channel description on the notification.
* `recorderErrors` stream for failures while recording (for example the camera was lost).
* Tests for the Dart API and the native size, orientation and folder name logic.

### Build
* Videos are written through `MediaStore` only; the Android 9 file-path code and `WRITE_EXTERNAL_STORAGE` are gone with the `minSdk 31` change.
* Kotlin, AGP 8.9, Gradle 8.12, Java 17, `compileSdk` 36. The plugin namespace was corrected.

## 1.0.0+2
* Added support for Android 14

## 0.0.9+1
* Fixed an issue that caused the plugin to not start recording when permissions are granted

## 0.0.9
* Updated documentation and example
* Updated dart code to implement `showToast` property

## 0.0.8
* You can now hide the toasts by setting the `showToast` property to false when calling `startVideoRecording()`

## 0.0.7
* Added support for front camera

## 0.0.6
* Updated documentation and README

## 0.0.5
* Fixed an issue which caused the plugin to crash when app is closed causing the recording to continue until force stopped.

## 0.0.4
* Fixed an issue that caused start recording to fail for the first time

## 0.0.3
* Removed permission to draw over other apps
* Added more documentation to code

## 0.0.2
* Updated README.md

## 0.0.1
* Initial release
