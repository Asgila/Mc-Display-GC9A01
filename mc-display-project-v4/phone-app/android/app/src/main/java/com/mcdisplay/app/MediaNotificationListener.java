package com.mcdisplay.app;

import android.app.Notification;
import android.content.ComponentName;
import android.content.Intent;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSession;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.util.Log;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Listens to notifications to capture:
 * 1. Media playback info (music title, artist, play state)
 * 2. Google Maps navigation instructions (turn directions, distance)
 */
public class MediaNotificationListener extends NotificationListenerService {
    private static final String TAG = "MCDisplay_NLS";
    private static final String GOOGLE_MAPS_PACKAGE = "com.google.android.apps.maps";

    // Static fields accessible from Flutter platform channel
    private static String currentTitle = "";
    private static String currentArtist = "";
    private static String currentState = "STOPPED";

    private static String navDistance = "";
    private static String navUnit = "";
    private static double navDirection = 0;
    private static String navInstruction = "";
    private static boolean navActive = false;

    private static MediaNotificationListener instance;
    private MediaSessionManager mediaSessionManager;

    // Callback interface for Flutter
    private static DataCallback dataCallback;

    public interface DataCallback {
        void onMediaChanged(Map<String, String> data);
        void onNavChanged(Map<String, String> data);
    }

    public static void setDataCallback(DataCallback callback) {
        dataCallback = callback;
    }

    public static Map<String, String> getMediaInfo() {
        Map<String, String> info = new HashMap<>();
        info.put("title", currentTitle);
        info.put("artist", currentArtist);
        info.put("state", currentState);
        return info;
    }

    public static Map<String, String> getNavInfo() {
        Map<String, String> info = new HashMap<>();
        info.put("distance", navDistance);
        info.put("unit", navUnit);
        info.put("direction", String.valueOf(navDirection));
        info.put("instruction", navInstruction);
        info.put("active", String.valueOf(navActive));
        return info;
    }

    public static boolean isRunning() {
        return instance != null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        Log.d(TAG, "NotificationListenerService created");

        // Set up MediaSessionManager to listen for media changes
        try {
            mediaSessionManager = (MediaSessionManager) getSystemService(MEDIA_SESSION_SERVICE);
            if (mediaSessionManager != null) {
                mediaSessionManager.addOnActiveSessionsChangedListener(
                    sessions -> updateMediaSessions(sessions),
                    new ComponentName(this, MediaNotificationListener.class)
                );
                // Get current sessions
                updateMediaSessions(mediaSessionManager.getActiveSessions(
                    new ComponentName(this, MediaNotificationListener.class)
                ));
            }
        } catch (SecurityException e) {
            Log.e(TAG, "SecurityException setting up MediaSessionManager: " + e.getMessage());
        }
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        instance = null;
        Log.d(TAG, "NotificationListenerService destroyed");
    }

    private void updateMediaSessions(List<MediaController> controllers) {
        if (controllers == null || controllers.isEmpty()) {
            currentState = "STOPPED";
            currentTitle = "";
            currentArtist = "";
            notifyMediaChanged();
            return;
        }

        // Use the first active controller
        MediaController controller = controllers.get(0);

        // Get metadata
        MediaMetadata metadata = controller.getMetadata();
        if (metadata != null) {
            CharSequence title = metadata.getText(MediaMetadata.METADATA_KEY_TITLE);
            CharSequence artist = metadata.getText(MediaMetadata.METADATA_KEY_ARTIST);
            if (artist == null) {
                artist = metadata.getText(MediaMetadata.METADATA_KEY_ALBUM_ARTIST);
            }
            currentTitle = title != null ? title.toString() : "";
            currentArtist = artist != null ? artist.toString() : "";
        }

        // Get playback state
        PlaybackState playbackState = controller.getPlaybackState();
        if (playbackState != null) {
            switch (playbackState.getState()) {
                case PlaybackState.STATE_PLAYING:
                    currentState = "PLAYING";
                    break;
                case PlaybackState.STATE_PAUSED:
                    currentState = "PAUSED";
                    break;
                default:
                    currentState = "STOPPED";
                    break;
            }
        }

        // Register callback for future changes
        controller.registerCallback(new MediaController.Callback() {
            @Override
            public void onMetadataChanged(MediaMetadata metadata) {
                if (metadata != null) {
                    CharSequence title = metadata.getText(MediaMetadata.METADATA_KEY_TITLE);
                    CharSequence artist = metadata.getText(MediaMetadata.METADATA_KEY_ARTIST);
                    if (artist == null) {
                        artist = metadata.getText(MediaMetadata.METADATA_KEY_ALBUM_ARTIST);
                    }
                    currentTitle = title != null ? title.toString() : "";
                    currentArtist = artist != null ? artist.toString() : "";
                    notifyMediaChanged();
                }
            }

            @Override
            public void onPlaybackStateChanged(PlaybackState state) {
                if (state != null) {
                    switch (state.getState()) {
                        case PlaybackState.STATE_PLAYING:
                            currentState = "PLAYING";
                            break;
                        case PlaybackState.STATE_PAUSED:
                            currentState = "PAUSED";
                            break;
                        default:
                            currentState = "STOPPED";
                            break;
                    }
                    notifyMediaChanged();
                }
            }
        });

        notifyMediaChanged();
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        if (sbn == null) return;

        String packageName = sbn.getPackageName();

        // Handle Google Maps navigation notifications
        if (GOOGLE_MAPS_PACKAGE.equals(packageName)) {
            handleGoogleMapsNotification(sbn);
        }
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        if (sbn == null) return;

        // If Google Maps notification is removed, navigation ended
        if (GOOGLE_MAPS_PACKAGE.equals(sbn.getPackageName())) {
            if (sbn.getNotification().extras != null) {
                navActive = false;
                navDistance = "";
                navUnit = "";
                navDirection = 0;
                navInstruction = "Navigation ended";
                notifyNavChanged();
                Log.d(TAG, "Google Maps navigation ended");
            }
        }
    }

    private void handleGoogleMapsNotification(StatusBarNotification sbn) {
        Notification notification = sbn.getNotification();
        Bundle extras = notification.extras;

        if (extras == null) return;

        String title = "";
        String text = "";

        CharSequence titleCs = extras.getCharSequence(Notification.EXTRA_TITLE);
        CharSequence textCs = extras.getCharSequence(Notification.EXTRA_TEXT);
        CharSequence bigTextCs = extras.getCharSequence(Notification.EXTRA_BIG_TEXT);

        if (titleCs != null) title = titleCs.toString();
        if (textCs != null) text = textCs.toString();
        if (bigTextCs != null && bigTextCs.length() > text.length()) {
            text = bigTextCs.toString();
        }

        Log.d(TAG, "Maps notification - Title: " + title + ", Text: " + text);

        // Parse Google Maps navigation notification
        // Typical formats:
        // Title: "5 min (2.1 km)" or "Turn left onto Main St"
        // Text: "Head north on Highway 1" or distance info
        if (title.isEmpty() && text.isEmpty()) return;

        // Try to extract turn direction and distance
        parseNavigationData(title, text);
    }

    private void parseNavigationData(String title, String text) {
        navActive = true;

        // Combine title and text for analysis
        String combined = (title + " " + text).toLowerCase();

        // Extract direction from keywords
        navDirection = parseDirection(combined);

        // Extract distance - look for patterns like "200 m", "1.5 km", "0.3 mi"
        Pattern distPattern = Pattern.compile("(\\d+[.,]?\\d*)\\s*(m|km|mi|ft|meters|kilometers|miles|feet)\\b");
        Matcher distMatcher = distPattern.matcher(combined);
        if (distMatcher.find()) {
            navDistance = distMatcher.group(1);
            navUnit = distMatcher.group(2);
            // Normalize units
            if ("meters".equals(navUnit)) navUnit = "m";
            if ("kilometers".equals(navUnit)) navUnit = "km";
            if ("miles".equals(navUnit)) navUnit = "mi";
            if ("feet".equals(navUnit)) navUnit = "ft";
        }

        // Use the title as the instruction (usually contains the turn instruction)
        // Filter out pure time/distance titles
        if (!title.isEmpty() && !title.matches("^\\d+\\s*(min|hr|sec).*")) {
            navInstruction = title;
        } else if (!text.isEmpty()) {
            navInstruction = text;
        }

        // Truncate instruction for display
        if (navInstruction.length() > 40) {
            navInstruction = navInstruction.substring(0, 40);
        }

        notifyNavChanged();
        Log.d(TAG, String.format("Nav parsed: %s %s, dir=%.0f, %s",
            navDistance, navUnit, navDirection, navInstruction));
    }

    /**
     * Parse direction from text.
     * Returns angle in degrees: 0=straight, 90=right, -90=left, 180=u-turn
     */
    private double parseDirection(String text) {
        // Check for U-turn first
        if (text.contains("u-turn") || text.contains("u turn") || text.contains("make a u")) {
            return 180;
        }

        // Check for sharp turns
        if (text.contains("sharp right")) return 135;
        if (text.contains("sharp left")) return -135;

        // Check for slight turns
        if (text.contains("slight right") || text.contains("bear right") || text.contains("keep right")) {
            return 45;
        }
        if (text.contains("slight left") || text.contains("bear left") || text.contains("keep left")) {
            return -45;
        }

        // Check for regular turns
        if (text.contains("turn right") || text.contains("right onto") || text.contains("right on ")) {
            return 90;
        }
        if (text.contains("turn left") || text.contains("left onto") || text.contains("left on ")) {
            return -90;
        }

        // Check for simple right/left at start of instruction
        if (text.startsWith("right")) return 90;
        if (text.startsWith("left")) return -90;

        // Roundabout
        if (text.contains("roundabout")) {
            if (text.contains("right") || text.contains("1st exit")) return 90;
            if (text.contains("left") || text.contains("3rd exit")) return -90;
            return 45; // Default roundabout direction
        }

        // Head/continue straight
        if (text.contains("head ") || text.contains("continue") || text.contains("straight")) {
            return 0;
        }

        // Merge
        if (text.contains("merge")) {
            if (text.contains("right")) return 45;
            if (text.contains("left")) return -45;
            return 0;
        }

        // Default: straight ahead
        return 0;
    }

    private void notifyMediaChanged() {
        if (dataCallback != null) {
            dataCallback.onMediaChanged(getMediaInfo());
        }
    }

    private void notifyNavChanged() {
        if (dataCallback != null) {
            dataCallback.onNavChanged(getNavInfo());
        }
    }
}
