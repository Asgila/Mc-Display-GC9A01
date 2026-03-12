package com.mcdisplay.app;

import android.app.Notification;
import android.content.ComponentName;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
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
 *
 * Direction is extracted from the notification's large icon (turn arrow bitmap)
 * because Google Maps in many locales (e.g. Danish) does not include direction
 * text in the notification — only the distance and street name.
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
    private static String navType = "turn";  // "turn" or "roundabout"

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
        info.put("type", navType);
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
                    navType = "turn";
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
        CharSequence subTextCs = extras.getCharSequence(Notification.EXTRA_SUB_TEXT);

        if (titleCs != null) title = titleCs.toString();
        if (textCs != null) text = textCs.toString();
        if (bigTextCs != null && bigTextCs.length() > text.length()) {
            text = bigTextCs.toString();
        }

        // Log all available text fields for debugging
        Log.d(TAG, "Maps notification - Title: " + title + ", Text: " + text
            + (subTextCs != null ? ", SubText: " + subTextCs : "")
            + (notification.tickerText != null ? ", Ticker: " + notification.tickerText : ""));

        // Parse Google Maps navigation notification
        if (title.isEmpty() && text.isEmpty()) return;

        // Extract the large icon bitmap for direction analysis
        Bitmap largeIcon = extractLargeIcon(notification, extras);

        parseNavigationData(title, text, subTextCs != null ? subTextCs.toString() : "", largeIcon);
    }

    /**
     * Extract the large icon bitmap from the notification.
     * Google Maps puts the turn direction arrow as the large icon.
     */
    private Bitmap extractLargeIcon(Notification notification, Bundle extras) {
        // Method 1: Get from extras (works on most API levels)
        try {
            Object largeIconObj = extras.get(Notification.EXTRA_LARGE_ICON);
            if (largeIconObj instanceof Bitmap) {
                return (Bitmap) largeIconObj;
            }
        } catch (Exception e) {
            Log.d(TAG, "Could not get large icon from extras: " + e.getMessage());
        }

        // Method 2: Get from notification directly (API 23+)
        try {
            android.graphics.drawable.Icon icon = notification.getLargeIcon();
            if (icon != null) {
                android.graphics.drawable.Drawable d = icon.loadDrawable(getApplicationContext());
                if (d instanceof android.graphics.drawable.BitmapDrawable) {
                    return ((android.graphics.drawable.BitmapDrawable) d).getBitmap();
                }
            }
        } catch (Exception e) {
            Log.d(TAG, "Could not get large icon from notification: " + e.getMessage());
        }

        return null;
    }

    private void parseNavigationData(String title, String text, String subText, Bitmap largeIcon) {
        navActive = true;

        // Combine title, text, and subtext for text-based analysis
        String combined = (title + " " + text + " " + subText).toLowerCase();

        // Detect if this is a roundabout instruction
        boolean isRoundabout = isRoundaboutInstruction(combined);
        navType = isRoundabout ? "roundabout" : "turn";

        // 1. Try text-based direction parsing first (works for English and locales
        //    where Google Maps includes turn text in the notification)
        double textDirection;
        if (isRoundabout) {
            textDirection = parseRoundaboutDirection(combined);
        } else {
            textDirection = parseDirection(combined);
        }

        // 2. If text parsing found no specific direction AND we have an icon,
        //    analyze the icon bitmap for direction
        double iconDirection = -1;
        if (largeIcon != null) {
            iconDirection = parseDirectionFromIcon(largeIcon);
        }

        // Use icon direction when text parsing didn't find anything specific
        if (iconDirection != -1 && textDirection == 0) {
            navDirection = iconDirection;
            Log.d(TAG, "Using icon-based direction: " + navDirection);
        } else if (textDirection != 0) {
            navDirection = textDirection;
            Log.d(TAG, "Using text-based direction: " + navDirection
                + (iconDirection != -1 ? " (icon said: " + iconDirection + ")" : ""));
        } else {
            navDirection = 0;
        }

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
        Log.d(TAG, String.format("Nav parsed: %s %s, dir=%.0f, type=%s, %s",
            navDistance, navUnit, navDirection, navType, navInstruction));
    }

    // -----------------------------------------------------------------------
    //  Roundabout detection and direction parsing
    // -----------------------------------------------------------------------

    /**
     * Detect if the notification text describes a roundabout maneuver.
     * Supports English, Danish, German, French, Spanish, Dutch, and Swedish.
     */
    private boolean isRoundaboutInstruction(String text) {
        return text.contains("roundabout") || text.contains("rotary")
            || text.contains("rundkørsel") || text.contains("rundkoersel")   // Danish
            || text.contains("kreisverkehr") || text.contains("kreisel")     // German
            || text.contains("rond-point") || text.contains("giratoire")     // French
            || text.contains("rotonda") || text.contains("glorieta")         // Spanish
            || text.contains("rotonde")                                       // Dutch
            || text.contains("rondell") || text.contains("cirkulationsplats"); // Swedish
    }

    /**
     * Parse the exit direction for a roundabout.
     * Maps exit numbers to approximate turn angles:
     *   1st exit → 45 (slight right)
     *   2nd exit → 90 (right / straight-through on small roundabouts)
     *   3rd exit → 0  (straight through)
     *   4th exit → -90 (left)
     *   5th exit → -135 (sharp left)
     *   6th+ exit → 180 (nearly U-turn / going back)
     *
     * Also checks for explicit direction keywords within the roundabout instruction.
     */
    private double parseRoundaboutDirection(String text) {
        // Check for explicit direction keywords first (most reliable when present)
        if (text.contains("u-turn") || text.contains("u turn") || text.contains("u-vending")
            || text.contains("vend om") || text.contains("kehrt")) {
            return 180;
        }
        if (text.contains("sharp right") || text.contains("skarpt til højre")
            || text.contains("skarpt til hoejre")) {
            return 135;
        }
        if (text.contains("sharp left") || text.contains("skarpt til venstre")) {
            return -135;
        }
        if (text.contains("slight right") || text.contains("svagt til højre")
            || text.contains("svagt til hoejre")) {
            return 45;
        }
        if (text.contains("slight left") || text.contains("svagt til venstre")) {
            return -45;
        }
        if (text.contains("turn right") || text.contains("drej til højre")
            || text.contains("drej til hoejre")) {
            return 90;
        }
        if (text.contains("turn left") || text.contains("drej til venstre")) {
            return -90;
        }
        if (text.contains("straight") || text.contains("ligeud") || text.contains("lige ud")
            || text.contains("geradeaus") || text.contains("tout droit")) {
            return 0;
        }

        // Try to extract exit number — supports English ordinals, digits, and
        // Danish/German/French/Spanish/Dutch/Swedish ordinal styles
        int exitNum = extractExitNumber(text);
        if (exitNum > 0) {
            Log.d(TAG, "Roundabout exit number: " + exitNum);
            switch (exitNum) {
                case 1: return 45;    // Slight right (first exit)
                case 2: return 90;    // Right / straight-ish
                case 3: return 0;     // Straight through
                case 4: return -90;   // Left
                case 5: return -135;  // Sharp left
                default: return 180;  // 6+ exits = nearly U-turn
            }
        }

        // Fallback: check for simple right/left keywords
        if (text.contains("right") || text.contains("højre") || text.contains("hoejre")
            || text.contains("rechts") || text.contains("droite") || text.contains("derecha")) {
            return 90;
        }
        if (text.contains("left") || text.contains("venstre")
            || text.contains("links") || text.contains("gauche") || text.contains("izquierda")) {
            return -90;
        }

        // Default roundabout: assume slight right (most common)
        return 45;
    }

    /**
     * Extract the exit number from roundabout instruction text.
     * Handles patterns like:
     *   English: "1st exit", "2nd exit", "3rd exit", "4th exit", "take the 2 exit"
     *   Danish:  "1. frakørsel", "2. udkørsel", "første", "anden", "tredje"
     *   German:  "1. Ausfahrt", "2. Ausfahrt", "erste", "zweite", "dritte"
     *   French:  "1re sortie", "2e sortie", "première", "deuxième", "troisième"
     *   Generic: any digit followed by exit-like words
     * Returns 0 if no exit number found.
     */
    private int extractExitNumber(String text) {
        // Pattern: digit + ordinal suffix + "exit" (English)
        Pattern exitPattern = Pattern.compile("(\\d+)\\s*(?:st|nd|rd|th)?\\s*(?:exit|afkørsel|frakørsel|udkørsel|frakoersel|udkoersel|ausfahrt|sortie|salida|afslag|avfart)");
        Matcher m = exitPattern.matcher(text);
        if (m.find()) {
            try { return Integer.parseInt(m.group(1)); }
            catch (NumberFormatException ignored) { }
        }

        // Pattern: "exit N" or "take the N" (English)
        Pattern exitNumAfter = Pattern.compile("(?:exit|take the)\\s+(\\d+)");
        m = exitNumAfter.matcher(text);
        if (m.find()) {
            try { return Integer.parseInt(m.group(1)); }
            catch (NumberFormatException ignored) { }
        }

        // Pattern: "N." followed by Danish/German exit words (e.g. "2. frakørsel")
        Pattern dotPattern = Pattern.compile("(\\d+)\\.\\s*(?:frakørsel|udkørsel|frakoersel|udkoersel|afkørsel|afkoersel|ausfahrt|sortie|salida|afslag|avfart)");
        m = dotPattern.matcher(text);
        if (m.find()) {
            try { return Integer.parseInt(m.group(1)); }
            catch (NumberFormatException ignored) { }
        }

        // Word-based ordinals (English)
        if (text.contains("first exit")) return 1;
        if (text.contains("second exit")) return 2;
        if (text.contains("third exit")) return 3;
        if (text.contains("fourth exit")) return 4;
        if (text.contains("fifth exit")) return 5;
        if (text.contains("sixth exit")) return 6;

        // Word-based ordinals (Danish)
        if (text.contains("første") || text.contains("foerste")) return 1;
        if (text.contains("anden") || text.contains("andet")) return 2;
        if (text.contains("tredje")) return 3;
        if (text.contains("fjerde")) return 4;
        if (text.contains("femte")) return 5;
        if (text.contains("sjette")) return 6;

        // Word-based ordinals (German)
        if (text.contains("erste")) return 1;
        if (text.contains("zweite")) return 2;
        if (text.contains("dritte")) return 3;
        if (text.contains("vierte")) return 4;
        if (text.contains("fünfte") || text.contains("fuenfte")) return 5;
        if (text.contains("sechste")) return 6;

        // Word-based ordinals (French)
        if (text.contains("première") || text.contains("premiere") || text.contains("1re")) return 1;
        if (text.contains("deuxième") || text.contains("deuxieme") || text.contains("2e")) return 2;
        if (text.contains("troisième") || text.contains("troisieme") || text.contains("3e")) return 3;
        if (text.contains("quatrième") || text.contains("quatrieme") || text.contains("4e")) return 4;
        if (text.contains("cinquième") || text.contains("cinquieme") || text.contains("5e")) return 5;
        if (text.contains("sixième") || text.contains("sixieme") || text.contains("6e")) return 6;

        return 0;
    }

    // -----------------------------------------------------------------------
    //  Icon-based direction detection
    // -----------------------------------------------------------------------

    /**
     * Analyze the notification's large icon bitmap to determine turn direction.
     *
     * Google Maps encodes the turn direction as an arrow icon. We analyze the
     * pixel distribution of the foreground (arrow) to determine which way it points:
     * - More arrow pixels on the right side → right turn
     * - More arrow pixels on the left side  → left turn
     * - Balanced/centered                   → straight or U-turn
     *
     * We weight the top half of the icon more heavily because the arrowhead
     * (the directional part) is there, while the stem at the bottom is always
     * centered regardless of direction.
     *
     * Returns the direction angle, or -1 if analysis failed.
     */
    private double parseDirectionFromIcon(Bitmap bitmap) {
        if (bitmap == null) return -1;

        int width = bitmap.getWidth();
        int height = bitmap.getHeight();
        if (width == 0 || height == 0) return -1;

        // Scale down large icons for performance (nav icons are typically small already)
        Bitmap scaled = bitmap;
        if (width > 128 || height > 128) {
            scaled = Bitmap.createScaledBitmap(bitmap, 64, 64, true);
            width = 64;
            height = 64;
        }

        // Determine background color from corners
        int bgColor = detectBackgroundColor(scaled, width, height);

        int midX = width / 2;
        int midY = height / 2;

        // Count foreground pixels in each quadrant
        int topLeftCount = 0;
        int topRightCount = 0;
        int bottomLeftCount = 0;
        int bottomRightCount = 0;
        int totalFg = 0;

        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int pixel = scaled.getPixel(x, y);
                if (isForegroundPixel(pixel, bgColor)) {
                    totalFg++;
                    if (y < midY) {
                        if (x < midX) topLeftCount++;
                        else topRightCount++;
                    } else {
                        if (x < midX) bottomLeftCount++;
                        else bottomRightCount++;
                    }
                }
            }
        }

        if (totalFg < 10) {
            Log.d(TAG, "Icon analysis: too few foreground pixels (" + totalFg + ")");
            return -1;
        }

        // Calculate biases
        int topTotal = topLeftCount + topRightCount;
        int leftTotal = topLeftCount + bottomLeftCount;
        int rightTotal = topRightCount + bottomRightCount;
        int bottomTotal = bottomLeftCount + bottomRightCount;

        // Top-half left-right bias: where the arrowhead points
        // Range: -1.0 (all top pixels on left) to +1.0 (all top pixels on right)
        double topBias = 0;
        if (topTotal > 0) {
            topBias = (double)(topRightCount - topLeftCount) / topTotal;
        }

        // Overall left-right bias
        double overallBias = (double)(rightTotal - leftTotal) / totalFg;

        // Vertical bias: positive = more pixels in top half
        double verticalBias = (double)(topTotal - bottomTotal) / totalFg;

        Log.d(TAG, String.format("Icon analysis: %dx%d, fg=%d, topBias=%.3f, overallBias=%.3f, vertBias=%.3f, "
            + "TL=%d TR=%d BL=%d BR=%d",
            width, height, totalFg, topBias, overallBias, verticalBias,
            topLeftCount, topRightCount, bottomLeftCount, bottomRightCount));

        // --- Determine direction ---

        // U-turn detection: arrow goes up then curves back, resulting in
        // relatively balanced left-right but significant top-half presence.
        // Straight arrows are typically bottom-heavy (long stem, small head).
        if (Math.abs(topBias) < 0.20 && Math.abs(overallBias) < 0.15 && verticalBias > -0.05) {
            Log.d(TAG, "Icon direction: U-Turn (180)");
            return 180;
        }

        // Use topBias (arrowhead position) as the primary direction signal
        if (topBias > 0.35) {
            Log.d(TAG, "Icon direction: Sharp Right (135)");
            return 135;
        } else if (topBias > 0.15) {
            Log.d(TAG, "Icon direction: Right (90)");
            return 90;
        } else if (topBias > 0.05) {
            Log.d(TAG, "Icon direction: Slight Right (45)");
            return 45;
        } else if (topBias < -0.35) {
            Log.d(TAG, "Icon direction: Sharp Left (-135)");
            return -135;
        } else if (topBias < -0.15) {
            Log.d(TAG, "Icon direction: Left (-90)");
            return -90;
        } else if (topBias < -0.05) {
            Log.d(TAG, "Icon direction: Slight Left (-45)");
            return -45;
        }

        Log.d(TAG, "Icon direction: Straight (0)");
        return 0;
    }

    /**
     * Detect the background color by sampling the corners of the bitmap.
     * Returns the most common corner color.
     */
    private int detectBackgroundColor(Bitmap bitmap, int width, int height) {
        int[] corners = new int[] {
            bitmap.getPixel(0, 0),
            bitmap.getPixel(width - 1, 0),
            bitmap.getPixel(0, height - 1),
            bitmap.getPixel(width - 1, height - 1)
        };

        // Find most common corner color
        HashMap<Integer, Integer> counts = new HashMap<>();
        for (int c : corners) {
            counts.put(c, counts.getOrDefault(c, 0) + 1);
        }

        int maxCount = 0;
        int bgColor = corners[0];
        for (Map.Entry<Integer, Integer> entry : counts.entrySet()) {
            if (entry.getValue() > maxCount) {
                maxCount = entry.getValue();
                bgColor = entry.getKey();
            }
        }
        return bgColor;
    }

    /**
     * Check if a pixel is foreground (part of the arrow) vs background.
     * A pixel is foreground if it has sufficient opacity AND differs enough
     * from the detected background color.
     */
    private boolean isForegroundPixel(int pixel, int bgColor) {
        // Transparent pixels are background
        if (Color.alpha(pixel) < 128) return false;

        // If background is also transparent, any opaque pixel is foreground
        if (Color.alpha(bgColor) < 128) return true;

        // Calculate color distance from background
        int dr = Color.red(pixel) - Color.red(bgColor);
        int dg = Color.green(pixel) - Color.green(bgColor);
        int db = Color.blue(pixel) - Color.blue(bgColor);
        double distance = Math.sqrt(dr * dr + dg * dg + db * db);

        return distance > 50;
    }

    // -----------------------------------------------------------------------
    //  Text-based direction parsing (fallback / for locales with text)
    // -----------------------------------------------------------------------

    /**
     * Parse direction from text keywords.
     * Returns angle in degrees: 0=straight, 90=right, -90=left, 180=u-turn.
     * Supports English and Danish keywords.
     */
    private double parseDirection(String text) {
        // === U-turn (check first — most specific) ===
        if (text.contains("u-turn") || text.contains("u turn") || text.contains("make a u")
            || text.contains("u-vending") || text.contains("vend om")) {
            return 180;
        }

        // === Sharp turns ===
        if (text.contains("sharp right") || text.contains("skarpt til højre")
            || text.contains("skarpt til hoejre")) {
            return 135;
        }
        if (text.contains("sharp left") || text.contains("skarpt til venstre")) {
            return -135;
        }

        // === Slight / keep / bear turns ===
        if (text.contains("slight right") || text.contains("bear right") || text.contains("keep right")
            || text.contains("hold til højre") || text.contains("hold til hoejre")
            || text.contains("svagt til højre") || text.contains("svagt til hoejre")) {
            return 45;
        }
        if (text.contains("slight left") || text.contains("bear left") || text.contains("keep left")
            || text.contains("hold til venstre") || text.contains("svagt til venstre")) {
            return -45;
        }

        // === Regular turns ===
        if (text.contains("turn right") || text.contains("right onto") || text.contains("right on ")
            || text.contains("drej til højre") || text.contains("drej til hoejre")
            || text.contains("til højre ad") || text.contains("til hoejre ad")) {
            return 90;
        }
        if (text.contains("turn left") || text.contains("left onto") || text.contains("left on ")
            || text.contains("drej til venstre") || text.contains("til venstre ad")) {
            return -90;
        }

        // === Simple right/left at start ===
        if (text.startsWith("right") || text.startsWith("højre") || text.startsWith("hoejre")) return 90;
        if (text.startsWith("left") || text.startsWith("venstre")) return -90;

        // === Roundabout (handled by parseRoundaboutDirection when detected,
        //     but keep as fallback in case parseDirection is called directly) ===
        if (isRoundaboutInstruction(text)) {
            return parseRoundaboutDirection(text);
        }

        // === Straight / continue ===
        if (text.contains("head ") || text.contains("continue") || text.contains("straight")
            || text.contains("fortsæt") || text.contains("fortsat") || text.contains("fortsaet")
            || text.contains("ligeud") || text.contains("lige ud")) {
            return 0;
        }

        // === Merge ===
        if (text.contains("merge") || text.contains("flet")) {
            if (text.contains("right") || text.contains("højre")) return 45;
            if (text.contains("left") || text.contains("venstre")) return -45;
            return 0;
        }

        // Default: no direction keywords found → return 0 (straight)
        // Icon analysis will override this if a large icon is available.
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
