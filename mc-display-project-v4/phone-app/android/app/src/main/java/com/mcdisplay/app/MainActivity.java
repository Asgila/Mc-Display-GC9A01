package com.mcdisplay.app;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.os.Bundle;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Log;
import android.view.KeyEvent;

import androidx.annotation.NonNull;

import java.util.Map;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String TAG = "MCDisplay_Main";
    private static final String MEDIA_CHANNEL = "com.mcdisplay.app/media";
    private static final String NAV_CHANNEL = "com.mcdisplay.app/navigation";

    private MethodChannel mediaChannel;
    private MethodChannel navChannel;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        // Media platform channel
        mediaChannel = new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(),
            MEDIA_CHANNEL
        );
        mediaChannel.setMethodCallHandler(this::handleMediaCall);

        // Navigation platform channel
        navChannel = new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(),
            NAV_CHANNEL
        );
        navChannel.setMethodCallHandler(this::handleNavCall);

        // Set up callbacks from NotificationListenerService to Flutter
        MediaNotificationListener.setDataCallback(new MediaNotificationListener.DataCallback() {
            @Override
            public void onMediaChanged(Map<String, String> data) {
                runOnUiThread(() -> {
                    if (mediaChannel != null) {
                        mediaChannel.invokeMethod("onMediaChanged", data);
                    }
                });
            }

            @Override
            public void onNavChanged(Map<String, String> data) {
                runOnUiThread(() -> {
                    if (navChannel != null) {
                        navChannel.invokeMethod("onNavChanged", data);
                    }
                });
            }
        });
    }

    private void handleMediaCall(MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "startMediaListener":
                if (isNotificationServiceEnabled()) {
                    result.success(true);
                } else {
                    result.success(false);
                }
                break;

            case "getMediaInfo":
                if (MediaNotificationListener.isRunning()) {
                    result.success(MediaNotificationListener.getMediaInfo());
                } else {
                    result.success(null);
                }
                break;

            case "checkPermission":
                result.success(isNotificationServiceEnabled());
                break;

            case "requestPermission":
                openNotificationListenerSettings();
                result.success(true);
                break;

            case "mediaControl":
                String action = call.argument("action");
                if (action != null) {
                    handleMediaControl(action);
                    result.success(true);
                } else {
                    result.error("INVALID", "No action provided", null);
                }
                break;

            default:
                result.notImplemented();
                break;
        }
    }

    private void handleMediaControl(String action) {
        AudioManager audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        if (audioManager == null) return;

        int keyCode;
        switch (action) {
            case "toggle":
                keyCode = KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE;
                break;
            case "next":
                keyCode = KeyEvent.KEYCODE_MEDIA_NEXT;
                break;
            case "previous":
                keyCode = KeyEvent.KEYCODE_MEDIA_PREVIOUS;
                break;
            default:
                Log.w(TAG, "Unknown media action: " + action);
                return;
        }

        // Send key down + key up events
        audioManager.dispatchMediaKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, keyCode));
        audioManager.dispatchMediaKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, keyCode));
        Log.d(TAG, "Media control dispatched: " + action);
    }

    private void handleNavCall(MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "getNavInfo":
                if (MediaNotificationListener.isRunning()) {
                    result.success(MediaNotificationListener.getNavInfo());
                } else {
                    result.success(null);
                }
                break;

            case "checkPermission":
                result.success(isNotificationServiceEnabled());
                break;

            case "requestPermission":
                openNotificationListenerSettings();
                result.success(true);
                break;

            default:
                result.notImplemented();
                break;
        }
    }

    /**
     * Check if our NotificationListenerService is enabled
     */
    private boolean isNotificationServiceEnabled() {
        String pkgName = getPackageName();
        String flat = Settings.Secure.getString(
            getContentResolver(),
            "enabled_notification_listeners"
        );
        if (!TextUtils.isEmpty(flat)) {
            String[] names = flat.split(":");
            for (String name : names) {
                ComponentName cn = ComponentName.unflattenFromString(name);
                if (cn != null && TextUtils.equals(pkgName, cn.getPackageName())) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Open the notification listener settings page
     */
    private void openNotificationListenerSettings() {
        Intent intent = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
        startActivity(intent);
    }
}
