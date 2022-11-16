package com.lightsoftware.flutter_background_video_recorder.flutter_background_video_recorder;

import static android.content.Context.BIND_AUTO_CREATE;

import static androidx.core.app.ActivityCompat.requestPermissions;
import static androidx.core.app.ActivityCompat.shouldShowRequestPermissionRationale;

import io.flutter.embedding.engine.plugins.activity.ActivityAware;

import android.Manifest;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.IBinder;
import android.provider.Settings;
import android.util.Log;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;

import java.util.HashMap;
import java.util.Map;

import flutter_bvr_service.VideoRecorderService;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;

/** FlutterBackgroundVideoRecorderPlugin */
public class FlutterBackgroundVideoRecorderPlugin extends BroadcastReceiver implements FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener, EventChannel.StreamHandler {
  private static final String TAG = "LightBackgroundVideoRecorder/Plugin";
  private static final int REQUEST_CAMERA_AUDIO_PERMISSION_RESULT = 4415;
  private static final int REQUEST_WRITE_PERMISSION_RESULT = 4416;

  public static final String RECORDING_RECEIVER = "RECORDING_RECEIVER";
  private static final int STATUS_RECORDING = 1;
  private static final int STATUS_STOPPED = 2;
  private static final int STATUS_INITIALIZING = 3;
  private static final int STATUS_EXCEPTION = -1;

  /// The MethodChannel and EventChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private MethodChannel channel;
  private EventChannel eventChannel;
  private EventChannel.EventSink mEventSink;
  private VideoRecorderService mVideoRecordingService;

  private Context mContext;
  private Activity mActivity;
  private final Map<String, Boolean> permissions = new HashMap<>();

  private int mRecordingStatus = STATUS_STOPPED;

  private final ServiceConnection mConnection = new ServiceConnection() {
    @Override
    public void onServiceConnected(ComponentName className, IBinder service) {
      Log.d(TAG, "Service connected");
      VideoRecorderService.LocalBinder binder = (VideoRecorderService.LocalBinder) service;
      mVideoRecordingService = binder.getServerInstance();
      boolean isRecording = mVideoRecordingService.getRecordingStatus();
      if (!isRecording)
        mVideoRecordingService.startVideoRecording();
      else
        Toast.makeText(
                mVideoRecordingService.getApplicationContext(),
                "Recording already in progress.",
                Toast.LENGTH_SHORT
        ).show();
    }

    @Override
    public void onServiceDisconnected(ComponentName arg0) {
      Log.d(TAG, "Service disconnected");
    }
  };

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
    channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "flutter_background_video_recorder");
    channel.setMethodCallHandler(this);

    eventChannel = new EventChannel(flutterPluginBinding.getBinaryMessenger(), "flutter_background_video_recorder_event");
    eventChannel.setStreamHandler(this);

    mContext = flutterPluginBinding.getApplicationContext();
    IntentFilter filter = new IntentFilter(RECORDING_RECEIVER);
    filter.addCategory(Intent.CATEGORY_DEFAULT);
    mContext.registerReceiver(this, filter);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "getRecordingStatus":
        result.success(mRecordingStatus);
        break;
      case "startVideoRecording":
        if (mRecordingStatus == STATUS_STOPPED) {
          if (shouldStartRecording()) {
            Intent backgroundServiceStartIntent = new Intent(mContext, VideoRecorderService.class);
            mActivity.startService(backgroundServiceStartIntent);
            mActivity.bindService(backgroundServiceStartIntent, mConnection, BIND_AUTO_CREATE);
          } else {
            Log.d(TAG, "Permissions not satisfied");
            checkPermissions();
          }
          result.success(true);
        } else {
          result.error(Integer.toString(10), "Recording in progress", "Recording already in progress");
        }
        break;
      case "stopVideoRecording":
        if (mRecordingStatus == STATUS_RECORDING) {
          String mVideoFileName = mVideoRecordingService.stopVideoRecording();
          mActivity.unbindService(mConnection);
          Toast.makeText(mContext, "File saved: " + mVideoFileName, Toast.LENGTH_SHORT).show();
          result.success(mVideoFileName);
        } else {
          result.error(Integer.toString(11), "Recording stopped", "Recording already stopped");
        }
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    eventChannel.setStreamHandler(null);
  }

  private void checkPermissions() {
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
      if (ContextCompat.checkSelfPermission(mContext, Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
              PackageManager.PERMISSION_GRANTED) {
        if (shouldShowRequestPermissionRationale(mActivity, Manifest.permission.WRITE_EXTERNAL_STORAGE)) {
          Toast.makeText(mContext, "Write permission is required to save videos", Toast.LENGTH_SHORT).show();
        }
        requestPermissions(mActivity, new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, REQUEST_WRITE_PERMISSION_RESULT);
      } else {
        Log.d(TAG, "WRITE permission granted");
        permissions.put("WRITE", true);
      }
    }
    if (ContextCompat.checkSelfPermission(mContext, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED
            || ContextCompat.checkSelfPermission(mContext, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      if (shouldShowRequestPermissionRationale(mActivity, Manifest.permission.CAMERA)) {
        Toast.makeText(mContext, "Camera permission is required to record videos", Toast.LENGTH_SHORT).show();
      }
      if (shouldShowRequestPermissionRationale(mActivity, Manifest.permission.RECORD_AUDIO)) {
        Toast.makeText(mContext, "Microphone permission is required to record videos", Toast.LENGTH_SHORT).show();
      }
      requestPermissions(mActivity, new String[] { Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO }, REQUEST_CAMERA_AUDIO_PERMISSION_RESULT);
    } else {
      Log.d(TAG, "CAMERA permission granted");
      Log.d(TAG, "MIC permission granted");
      permissions.put("CAMERA", true);
      permissions.put("MIC", true);
    }
  }

  private boolean shouldStartRecording() {
    boolean result;
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
      result = Boolean.TRUE.equals(permissions.get("WRITE"))
              && Boolean.TRUE.equals(permissions.get("MIC"))
              && Boolean.TRUE.equals(permissions.get("CAMERA"));
    } else {
      result = Boolean.TRUE.equals(permissions.get("MIC"))
              && Boolean.TRUE.equals(permissions.get("CAMERA"));
    }
    if (!Settings.canDrawOverlays(mContext)) {
      result = false;
      Toast.makeText(mContext, "Enable draw over other apps for LightBackgroundVideoRecorder", Toast.LENGTH_SHORT).show();
      Intent intent = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + mContext.getPackageName()));
      mActivity.startActivity(intent);
    }
    return result;
  }

  @Override
  public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
    switch (requestCode) {
      case REQUEST_CAMERA_AUDIO_PERMISSION_RESULT:
        if (grantResults[0] != PackageManager.PERMISSION_GRANTED) {
          Toast.makeText(mContext, "Camera permission denied by user", Toast.LENGTH_SHORT).show();
        } else {
          this.permissions.put("CAMERA", true);
        }
        if (grantResults[1] != PackageManager.PERMISSION_GRANTED) {
          Toast.makeText(mContext, "Record audio permission denied by user", Toast.LENGTH_SHORT).show();
        } else {
          this.permissions.put("MIC", true);
        }
        break;
      case REQUEST_WRITE_PERMISSION_RESULT:
        if (grantResults[0] != PackageManager.PERMISSION_GRANTED) {
          Toast.makeText(mContext, "Write permission denied by user", Toast.LENGTH_SHORT).show();
        } else {
          this.permissions.put("WRITE", true);
        }
    }
    return true;
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    mActivity = binding.getActivity();
    binding.addRequestPermissionsResultListener(this);
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    mActivity = null;
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    mActivity = binding.getActivity();
    binding.addRequestPermissionsResultListener(this);
  }

  @Override
  public void onDetachedFromActivity() {
    mActivity = null;
  }

  @Override
  public void onListen(Object arguments, EventChannel.EventSink events) {
    mEventSink = events;
  }

  @Override
  public void onCancel(Object arguments) {
    mEventSink = null;
  }

  @Override
  public void onReceive(Context context, Intent intent) {
    String message = intent.getStringExtra("msg");
    String code = intent.getStringExtra("code");
    Toast.makeText(mContext, message, Toast.LENGTH_SHORT).show();
    Log.i(TAG, "Received code " + code + " with message: " + message);
    switch (code) {
      case "RECORDING":
        mRecordingStatus = STATUS_RECORDING;
        mEventSink.success(STATUS_RECORDING);
        break;
      case "STOPPED":
        mRecordingStatus = STATUS_STOPPED;
        mEventSink.success(STATUS_STOPPED);
        break;
      case "INITIALIZING":
        mRecordingStatus = STATUS_INITIALIZING;
        mEventSink.success(STATUS_INITIALIZING);
        break;
      case "EXCEPTION":
        mRecordingStatus = STATUS_EXCEPTION;
        mEventSink.success(STATUS_EXCEPTION);
        Toast.makeText(mContext, "An exception occurred in recording service", Toast.LENGTH_SHORT).show();
        break;
      default:
        Toast.makeText(mContext, "Illegal broadcast received", Toast.LENGTH_SHORT).show();
    }
  }
}
