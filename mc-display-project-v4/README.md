# MC Display - Motorcycle ESP32 Round Display

A complete system for displaying time, music info, and Google Maps navigation on a round GC9A01 display (240x240) connected to an ESP32-S3, controlled from your Android phone via BLE.

## Overview

The system has two parts:

1. **ESP32 Firmware** (`esp32-firmware/`) - Runs on the ESP32-S3 with a round display
2. **Android Phone App** (`phone-app/`) - Flutter app that auto-connects and sends data

### Features

- **Time Display** - Syncs time from your phone on every power-on (no RTC needed)
- **Music Info** - Automatically reads what's playing on your phone (Spotify, YouTube Music, etc.)
- **Google Maps Navigation** - Reads turn-by-turn directions from Google Maps notifications
- **Auto-connect** - Phone app automatically finds and connects to the ESP32
- **3 Slides** - Switch between Time, Music, and Navigation views from the app

## Hardware

- ESP32-S3 with GC9A01 240x240 round display
- 8-bit parallel interface (pins defined in firmware)
- Connected to motorcycle battery (powers on with ignition)

## Setup

### ESP32 Firmware

1. Install [PlatformIO](https://platformio.org/) (VS Code extension or CLI)
2. Open the `esp32-firmware/` folder in PlatformIO
3. Build and upload:
   ```bash
   cd esp32-firmware
   pio run --target upload
   ```
4. The display will show "BLE Ready..." waiting for the phone

### Phone App (Android)

1. Install [Flutter](https://flutter.dev/docs/get-started/install) (3.10+)
2. Create the Flutter project and copy in the source files:
   ```bash
   cd phone-app
   flutter create . --org com.mcdisplay --project-name mc_display
   ```
   (This generates the missing boilerplate files. Your existing source files will NOT be overwritten.)
3. Build and install:
   ```bash
   flutter pub get
   flutter run
   ```

### First-Time Setup on Phone

1. **Bluetooth** - Enable Bluetooth and grant location permission when prompted
2. **Notification Access** - The app needs notification listener permission to read:
   - Music playback info (from any media player)
   - Google Maps navigation directions
   
   Go to the Music or Navigation tab and tap "Grant Permission" to open Android settings.
   Find "MC Display" in the notification access list and enable it.

## How It Works

### Power-On Flow (Every Ride)
1. Turn ignition on → ESP32 powers up, shows "BLE Ready..."
2. Phone app (running in background) detects the ESP32 and auto-connects
3. Phone immediately sends current time → clock is synced
4. Music info and navigation data start flowing automatically

### BLE Protocol

The phone sends text commands to the ESP32 over BLE UART:

| Command | Format | Example |
|---------|--------|---------|
| Time sync | `TIME <unix_epoch>` | `TIME 1710168000` |
| Music info | `MUSIC <state>\|<title>\|<artist>` | `MUSIC PLAYING\|Bohemian Rhapsody\|Queen` |
| Navigation | `NAV <dist>\|<unit>\|<direction>\|<instruction>` | `NAV 200\|m\|-90\|Turn left on Main St` |
| Switch slide | `SLIDE <0-2>` | `SLIDE 1` (music) |
| Next/prev slide | `NEXT_SLIDE` / `PREV_SLIDE` | |

Navigation direction is in degrees: 0=straight, 90=right, -90=left, 180=u-turn

### Slide System

| Slide | Index | Content |
|-------|-------|---------|
| Time | 0 | Large digital clock (HH:MM with seconds below) |
| Music | 1 | Track title, artist, play/pause/next icons |
| Navigation | 2 | Distance, direction arrow, turn instruction |

Switch slides from the app bar icons or via BLE commands.

## Google Maps Integration

The app reads Google Maps navigation notifications using Android's NotificationListenerService. When you start navigation in Google Maps:

1. Turn-by-turn directions appear in the notification bar
2. The app parses the notification text to extract:
   - Direction (left, right, straight, u-turn, etc.)
   - Distance to next turn
   - Turn instruction text
3. This data is sent to the ESP32 display in real-time

**Supported turn types:** straight, slight left/right, left/right, sharp left/right, u-turn, roundabout, merge

## Project Structure

```
mc-display-project/
├── esp32-firmware/
│   ├── platformio.ini          # PlatformIO config
│   └── src/
│       └── main.cpp            # Complete ESP32 firmware
├── phone-app/
│   ├── pubspec.yaml            # Flutter dependencies
│   ├── lib/
│   │   ├── main.dart           # App entry point
│   │   ├── screens/
│   │   │   ├── home_screen.dart      # Main screen with tabs
│   │   │   ├── connection_tab.dart   # BLE connection management
│   │   │   ├── music_tab.dart        # Music info display
│   │   │   └── navigation_tab.dart   # Navigation display + test
│   │   └── services/
│   │       ├── ble_service.dart       # BLE communication
│   │       ├── media_service.dart     # Music playback reading
│   │       └── navigation_service.dart # Google Maps nav reading
│   └── android/
│       └── app/src/main/
│           ├── AndroidManifest.xml              # Permissions
│           └── java/com/mcdisplay/app/
│               ├── MainActivity.java            # Platform channels
│               └── MediaNotificationListener.java # Notification reader
└── README.md
```

## Timezone

The ESP32 firmware is configured for Central European Time (CET/CEST) with automatic DST handling. To change the timezone, modify these constants in `main.cpp`:

```cpp
const int TIMEZONE_OFFSET = 1;  // Standard time offset from UTC
const int DST_OFFSET = 2;       // Daylight saving time offset from UTC
```

## Troubleshooting

- **Display shows "BLE Ready..." forever** - Make sure the phone app is running and Bluetooth is enabled
- **Music info not updating** - Check that notification access permission is granted for MC Display
- **Google Maps directions not showing** - Same notification access permission is needed. Make sure Google Maps navigation is actively running (not just the map view)
- **Time is wrong** - Check timezone constants in the firmware. The phone sends UTC epoch time and the ESP32 converts it
- **BLE connection drops** - The app will auto-reconnect. If it keeps dropping, check that the ESP32 is within BLE range (~10m)
