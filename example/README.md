# flutter_background_video_recorder example

A camera-style viewfinder built on the plugin: a live preview, a record button with a timer,
Video / Audio modes, and a settings sheet for aspect ratio, resolution, frame rate and codec.

Run it on an Android 12+ device or emulator:

```
flutter run
```

Where to look:

* `lib/recorder_controller.dart` holds all the state and what the buttons do. It is the part to
  read to see how to use the plugin.
* `lib/viewfinder_page.dart` draws the screen, including the `RecorderPreview` widget.
* `lib/settings_sheet.dart` builds its pickers from `getVideoCapabilities()`.
