# flutter_background_video_recorder example

A camera-style viewfinder built on the plugin: a full-width live preview with the controls floating
over it, a record button with a timer, a lens picker (UW / W / T / M), zoom discs that become a fine
wheel when dragged, Video / Audio modes, and a settings sheet for aspect ratio, resolution, frame
rate and codec. The **Streams** mode shows the raw frame and audio streams, with several listeners
on each session.

Run it on an Android 12+ device or emulator:

```
flutter run
```

Where to look:

* `lib/recorder_controller.dart` holds the state of recording, cameras and zoom, and what the
  buttons do. It is the part to read to see how to use the plugin.
* `lib/streams_controller.dart` opens the raw sessions and shares them between listeners
  (`RawFeed`); `lib/frame_view.dart` shows how a frame is read in place and retained while it is
  decoded.
* `lib/viewfinder_page.dart` lays the screen out; `viewfinder_stage.dart` draws the picture
  (including the `RecorderPreview` widget), `viewfinder_top_bar.dart` and
  `viewfinder_bottom_bar.dart` the controls.
* `lib/camera_picker.dart` and `lib/zoom_selector.dart` are the lens and zoom controls.
* `lib/settings_sheet.dart` builds its pickers from `getVideoCapabilities()`.
