#include <Arduino.h>
#include <Arduino_GFX_Library.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <Wire.h>
#include <math.h>

// ====== COLOR DEFINITIONS (RGB565) ======
#ifndef BLACK
#define BLACK   0x0000
#endif
#ifndef WHITE
#define WHITE   0xFFFF
#endif
#ifndef GREEN
#define GREEN   0x07E0
#endif
#ifndef CYAN
#define CYAN    0x07FF
#endif
#ifndef BLUE
#define BLUE    0x001F
#endif
#ifndef YELLOW
#define YELLOW  0xFFE0
#endif
#ifndef RED
#define RED     0xF800
#endif

// ====== DISPLAY PINS ======
#define TFT_DC    18
#define TFT_CS    2
#define TFT_WR    3
#define TFT_RST   21
#define TFT_BL    42
#define TFT_D0    10
#define TFT_D1    11
#define TFT_D2    12
#define TFT_D3    13
#define TFT_D4    14
#define TFT_D5    15
#define TFT_D6    16
#define TFT_D7    17

// Display is 240x240 round (GC9A01)
#define SCREEN_W  240
#define SCREEN_H  240
#define CENTER_X  120
#define CENTER_Y  120

// ====== I2C / TOUCH PINS ======
#define I2C_SDA   8
#define I2C_SCL   9
#define TOUCH_RST 0
#define TOUCH_I2C_ADDR 0x15

// CST816 Registers
#define CST816_GESTURE_REG    0x01
#define CST816_FINGER_NUM_REG 0x02
#define CST816_XPOS_H_REG    0x03
#define CST816_XPOS_L_REG    0x04
#define CST816_YPOS_H_REG    0x05
#define CST816_YPOS_L_REG    0x06
#define CST816_CHIP_ID_REG    0xA7

// Gesture IDs
#define GESTURE_NONE        0x00
#define GESTURE_SWIPE_UP    0x01
#define GESTURE_SWIPE_DOWN  0x02
#define GESTURE_SWIPE_LEFT  0x03
#define GESTURE_SWIPE_RIGHT 0x04
#define GESTURE_SINGLE_TAP  0x05
#define GESTURE_DOUBLE_TAP  0x0B
#define GESTURE_LONG_PRESS  0x0C

Arduino_DataBus *bus = new Arduino_ESP32LCD8(
  TFT_DC, TFT_CS, TFT_WR, -1,
  TFT_D0, TFT_D1, TFT_D2, TFT_D3, TFT_D4, TFT_D5, TFT_D6, TFT_D7
);
Arduino_GFX *gfx = new Arduino_GC9A01(bus, TFT_RST, 0, true);

// ====== BLE CONFIG ======
#define SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_RX   "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_TX   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEServer *pServer;
BLECharacteristic *pTxCharacteristic;
bool deviceConnected = false;

// ====== SLIDE SYSTEM ======
enum Slide { SLIDE_TIME = 0, SLIDE_MUSIC = 1, SLIDE_NAV = 2, SLIDE_COUNT = 3 };
Slide currentSlide = SLIDE_TIME;
bool slideNeedsRedraw = true;
unsigned long lastSlideSwitch = 0;
const unsigned long SLIDE_AUTO_SWITCH_MS = 8000;
bool autoSlideEnabled = false;

// ====== TOUCH STATE ======
bool touchInitialized = false;
bool gestureActive = false;        // True from gesture detection until finger fully lifted
unsigned long gestureLockedUntil = 0; // Hard lock: ignore everything until this time

// ====== CLOCK MODE ======
bool analogClock = false;  // false = digital, true = analog

// ====== TIME DATA ======
int hours = 0;
int minutes = 0;
int seconds = 0;
bool timeInitialized = false;
unsigned long lastSecondMillis = 0;

// Timezone configuration (Central European Time)
const int TIMEZONE_OFFSET = 1;  // CET = UTC+1
const int DST_OFFSET = 2;       // CEST = UTC+2

// ====== MUSIC DATA ======
String musicTitle = "";
String musicArtist = "";
String musicState = "STOPPED"; // PLAYING, PAUSED, STOPPED
bool musicDataReceived = false;

// ====== NAVIGATION DATA ======
String navDistance = "";
String navUnit = "";
float navDirection = 0;
String navInstruction = "";
bool navDataReceived = false;

// ====== COLORS ======
#define COLOR_BG        BLACK
#define COLOR_TIME      0x07E0  // Green
#define COLOR_TIME_SEC  0x0400  // Dark green
#define COLOR_MUSIC_BG  BLACK
#define COLOR_MUSIC_TITLE  WHITE
#define COLOR_MUSIC_ARTIST 0x07FF // Cyan
#define COLOR_MUSIC_ICON   0x07E0 // Green
#define COLOR_NAV_BG    BLACK
#define COLOR_NAV_DIST  WHITE
#define COLOR_NAV_ARROW 0x001F  // Blue
#define COLOR_NAV_INST  0xFFE0  // Yellow
#define COLOR_INDICATOR 0x4208  // Dim gray
#define COLOR_INDICATOR_ACTIVE WHITE

// ====== FUNCTION DECLARATIONS ======
void processData(String msg);
void drawSlide();
void drawTimeSlide();
void drawMusicSlide();
void drawNavSlide();
void drawSlideIndicators();
void drawCenteredText(const char* text, int y, int size, uint16_t color);
void drawWrappedText(const char* text, int y, int maxWidth, int size, uint16_t color);
void drawPlayIcon(int cx, int cy, int size, uint16_t color);
void drawPauseIcon(int cx, int cy, int size, uint16_t color);
void drawNextIcon(int cx, int cy, int size, uint16_t color);
void drawPrevIcon(int cx, int cy, int size, uint16_t color);
void drawNavArrow(int cx, int cy, float angleDeg, int size, uint16_t color);
void initializeTimeFromEpoch(unsigned long epochTime);
void incrementTime();
int calculateDayOfWeek(int y, int m, int d);
bool isDST(int month, int day, int dayOfWeek, int hour);
void touchInit();
void handleTouch();
void handleMusicTap(int x, int y);
void sendBleCommand(const char* cmd);

// ====== BLE CALLBACKS ======
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("Phone connected!");
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("Phone disconnected!");
    pServer->getAdvertising()->start();
  }
};

class MyCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String value = pCharacteristic->getValue();
    if (value.length() > 0) {
      String receivedData = value;
      Serial.println("Received: " + receivedData);
      processData(receivedData);
    }
  }
};

// ====== TOUCH FUNCTIONS ======
void touchInit() {
  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(400000);
  delay(10);

  // Reset touch controller
  pinMode(TOUCH_RST, OUTPUT);
  digitalWrite(TOUCH_RST, LOW);
  delay(10);
  digitalWrite(TOUCH_RST, HIGH);
  delay(50);

  // Read chip ID to verify touch controller is present
  Wire.beginTransmission(TOUCH_I2C_ADDR);
  Wire.write(CST816_CHIP_ID_REG);
  if (Wire.endTransmission(false) == 0) {
    Wire.requestFrom((int)TOUCH_I2C_ADDR, 1, 1);
    if (Wire.available()) {
      uint8_t chipId = Wire.read();
      Serial.printf("Touch chip ID: 0x%02X\n", chipId);
      if (chipId != 0x00 && chipId != 0xFF) {
        touchInitialized = true;
        Serial.println("Touch initialized successfully");
      } else {
        Serial.println("Touch chip ID invalid, touch disabled");
      }
    }
  } else {
    Serial.println("Touch I2C communication failed, touch disabled");
  }
}

// Read gesture + finger count + coordinates in one I2C transaction
// Returns gesture code; fills fingerCount, x, y
uint8_t touchReadAll(uint8_t &fingerCount, int &x, int &y) {
  if (!touchInitialized) { fingerCount = 0; return GESTURE_NONE; }

  // Read registers 0x01 through 0x06 in one burst (6 bytes)
  Wire.beginTransmission(TOUCH_I2C_ADDR);
  Wire.write(CST816_GESTURE_REG);  // start at 0x01
  if (Wire.endTransmission(false) != 0) { fingerCount = 0; return GESTURE_NONE; }

  Wire.requestFrom((int)TOUCH_I2C_ADDR, 6, 1);
  if (Wire.available() < 6) { fingerCount = 0; return GESTURE_NONE; }

  uint8_t gesture = Wire.read();   // 0x01 gesture
  fingerCount = Wire.read();       // 0x02 finger count
  uint8_t xH = Wire.read();       // 0x03
  uint8_t xL = Wire.read();       // 0x04
  uint8_t yH = Wire.read();       // 0x05
  uint8_t yL = Wire.read();       // 0x06

  int rawX = ((xH & 0x0F) << 8) | xL;
  int rawY = ((yH & 0x0F) << 8) | yL;

  // Match display orientation (flip X as in demo)
  x = 239 - rawX;
  if (x < 0) x = 0; if (x > 239) x = 239;
  y = rawY;
  if (y < 0) y = 0; if (y > 239) y = 239;

  return gesture;
}


void sendBleCommand(const char* cmd) {
  if (deviceConnected && pTxCharacteristic != nullptr) {
    pTxCharacteristic->setValue(cmd);
    pTxCharacteristic->notify();
    Serial.printf("BLE TX: %s\n", cmd);
  }
}

void handleMusicTap(int x, int y) {
  if (!musicDataReceived) return;

  // Transport controls at y = SCREEN_H - 55 = 185
  // Enlarged touch area for glove use (y > 130 instead of 155)
  if (y < 130) return;

  Serial.printf("Music tap at (%d, %d)\n", x, y);

  if (x < 80) {
    // Previous track - wide left zone for gloves
    sendBleCommand("MEDIA PREV");
    Serial.println("Touch: Previous track");
    gfx->drawCircle(CENTER_X - 55, SCREEN_H - 55, 35, WHITE);
  } else if (x > 160) {
    // Next track - wide right zone for gloves
    sendBleCommand("MEDIA NEXT");
    Serial.println("Touch: Next track");
    gfx->drawCircle(CENTER_X + 55, SCREEN_H - 55, 35, WHITE);
  } else {
    // Play/Pause toggle - center zone
    sendBleCommand("MEDIA TOGGLE");
    Serial.println("Touch: Play/Pause toggle");
    gfx->drawCircle(CENTER_X, SCREEN_H - 55, 35, WHITE);
  }

  delay(100);
  slideNeedsRedraw = true;
}

void handleTouch() {
  if (!touchInitialized) return;

  unsigned long now = millis();

  // HARD LOCK: After acting on any gesture, completely ignore ALL touch input
  // for 1 second. This defeats the CST816 burst pattern where the chip
  // rapidly alternates gesture/NONE/gesture/NONE for the entire touch duration.
  if (now < gestureLockedUntil) return;

  uint8_t fingerCount = 0;
  int tx = 0, ty = 0;
  uint8_t gesture = touchReadAll(fingerCount, tx, ty);

  // If finger is on screen but we already handled this touch, skip
  if (fingerCount > 0 && gestureActive) return;

  // If finger is off screen, reset state for next touch
  if (fingerCount == 0) {
    gestureActive = false;
    return;
  }

  // Finger is on screen, gesture not yet handled, and we have a gesture
  if (gesture == GESTURE_NONE) return;

  // === ACT ON GESTURE EXACTLY ONCE ===
  gestureActive = true;
  gestureLockedUntil = now + 1000;  // Block everything for 1 full second

  Serial.printf("Gesture: 0x%02X  fingers:%d  xy:(%d,%d)\n", gesture, fingerCount, tx, ty);

  switch (gesture) {
    case GESTURE_SWIPE_LEFT:
      currentSlide = (Slide)((currentSlide + SLIDE_COUNT - 1) % SLIDE_COUNT);
      slideNeedsRedraw = true;
      lastSlideSwitch = millis();
      Serial.println("Touch: Swipe Left -> Prev Slide");
      break;

    case GESTURE_SWIPE_RIGHT:
      currentSlide = (Slide)((currentSlide + 1) % SLIDE_COUNT);
      slideNeedsRedraw = true;
      lastSlideSwitch = millis();
      Serial.println("Touch: Swipe Right -> Next Slide");
      break;

    case GESTURE_SINGLE_TAP: {
      Serial.printf("Tap at (%d, %d) on slide %d\n", tx, ty, (int)currentSlide);
      if (currentSlide == SLIDE_MUSIC) {
        handleMusicTap(tx, ty);
      } else if (currentSlide == SLIDE_TIME) {
        analogClock = !analogClock;
        slideNeedsRedraw = true;
        Serial.printf("Clock mode: %s\n", analogClock ? "analog" : "digital");
      }
      break;
    }

    case GESTURE_SWIPE_UP:
      Serial.println("Touch: Swipe Up");
      break;

    case GESTURE_SWIPE_DOWN:
      Serial.println("Touch: Swipe Down");
      break;

    default:
      break;
  }
}

// ====== DST CALCULATION ======
bool isDST(int month, int day, int dayOfWeek, int hour) {
  if (month < 3 || month > 10) return false;
  if (month > 3 && month < 10) return true;
  if (month == 3) {
    int lastSunday = 31 - (dayOfWeek % 7);
    return day >= lastSunday;
  }
  if (month == 10) {
    int lastSunday = 31 - (dayOfWeek % 7);
    return day < lastSunday;
  }
  return false;
}

int calculateDayOfWeek(int y, int m, int d) {
  if (m < 3) { m += 12; y -= 1; }
  int k = y % 100;
  int j = y / 100;
  int h = (d + (13*(m+1))/5 + k + (k/4) + (j/4) + 5*j) % 7;
  return (h + 5) % 7;
}

// ====== TIME FUNCTIONS ======
void initializeTimeFromEpoch(unsigned long epochTime) {
  unsigned long totalSeconds = epochTime;
  seconds = totalSeconds % 60;
  totalSeconds /= 60;
  minutes = totalSeconds % 60;
  totalSeconds /= 60;

  int hoursUTC = totalSeconds % 24;
  unsigned long totalDays = totalSeconds / 24;

  // Calculate date from days since epoch
  int year = 1970;
  int month, day;

  while (true) {
    int daysInYear = 365;
    if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) daysInYear = 366;
    if (totalDays < (unsigned long)daysInYear) break;
    totalDays -= daysInYear;
    year++;
  }

  int daysInMonth[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) daysInMonth[1] = 29;

  for (month = 0; month < 12; month++) {
    if ((int)totalDays < daysInMonth[month]) break;
    totalDays -= daysInMonth[month];
  }
  day = totalDays + 1;
  month += 1;

  int dayOfWeek = calculateDayOfWeek(year, month, day);
  bool dstActive = isDST(month, day, dayOfWeek, hoursUTC);
  int timezoneOff = dstActive ? DST_OFFSET : TIMEZONE_OFFSET;

  hours = hoursUTC + timezoneOff;
  if (hours >= 24) hours -= 24;
  else if (hours < 0) hours += 24;

  timeInitialized = true;
  slideNeedsRedraw = true;

  Serial.printf("Epoch: %lu -> Local: %02d:%02d:%02d (DST: %s)\n",
                epochTime, hours, minutes, seconds, dstActive ? "Yes" : "No");
}

void incrementTime() {
  seconds++;
  if (seconds >= 60) {
    seconds = 0;
    minutes++;
    if (minutes >= 60) {
      minutes = 0;
      hours++;
      if (hours >= 24) hours = 0;
    }
  }
}

// ====== DATA PROCESSING ======
void processData(String msg) {
  msg.trim();

  if (msg.startsWith("TIME ")) {
    String t = msg.substring(5);
    t.trim();
    unsigned long epochTime = strtoul(t.c_str(), NULL, 10);
    if (epochTime > 1000000000UL) {
      initializeTimeFromEpoch(epochTime);
    }
  }
  else if (msg.startsWith("MUSIC ")) {
    // Format: MUSIC state|title|artist
    String data = msg.substring(6);
    int sep1 = data.indexOf('|');
    int sep2 = data.indexOf('|', sep1 + 1);

    if (sep1 > 0 && sep2 > sep1) {
      musicState = data.substring(0, sep1);
      musicTitle = data.substring(sep1 + 1, sep2);
      musicArtist = data.substring(sep2 + 1);
      musicDataReceived = true;
      if (currentSlide == SLIDE_MUSIC) slideNeedsRedraw = true;
      Serial.printf("Music: %s - %s [%s]\n", musicArtist.c_str(), musicTitle.c_str(), musicState.c_str());
    }
  }
  else if (msg.startsWith("NAV ")) {
    // Format: NAV distance|unit|direction|instruction
    String data = msg.substring(4);
    int sep1 = data.indexOf('|');
    int sep2 = data.indexOf('|', sep1 + 1);
    int sep3 = data.indexOf('|', sep2 + 1);

    if (sep1 > 0 && sep2 > sep1 && sep3 > sep2) {
      navDistance = data.substring(0, sep1);
      navUnit = data.substring(sep1 + 1, sep2);
      navDirection = data.substring(sep2 + 1, sep3).toFloat();
      navInstruction = data.substring(sep3 + 1);
      navDataReceived = true;
      if (currentSlide == SLIDE_NAV) slideNeedsRedraw = true;
      Serial.printf("Nav: %s %s, dir=%.0f, %s\n", navDistance.c_str(), navUnit.c_str(), navDirection, navInstruction.c_str());
    }
  }
  else if (msg.startsWith("SLIDE ")) {
    int s = msg.substring(6).toInt();
    if (s >= 0 && s < SLIDE_COUNT) {
      currentSlide = (Slide)s;
      slideNeedsRedraw = true;
      lastSlideSwitch = millis();
      Serial.printf("Switched to slide %d\n", s);
    }
  }
  else if (msg == "NEXT_SLIDE") {
    currentSlide = (Slide)((currentSlide + 1) % SLIDE_COUNT);
    slideNeedsRedraw = true;
    lastSlideSwitch = millis();
  }
  else if (msg == "PREV_SLIDE") {
    currentSlide = (Slide)((currentSlide + SLIDE_COUNT - 1) % SLIDE_COUNT);
    slideNeedsRedraw = true;
    lastSlideSwitch = millis();
  }
  else if (msg == "AUTO_ON") {
    autoSlideEnabled = true;
  }
  else if (msg == "AUTO_OFF") {
    autoSlideEnabled = false;
  }
}

// ====== DRAWING HELPERS ======
void drawCenteredText(const char* text, int y, int size, uint16_t color) {
  gfx->setTextSize(size);
  gfx->setTextColor(color);
  int16_t x1, y1;
  uint16_t w, h;
  gfx->getTextBounds(text, 0, 0, &x1, &y1, &w, &h);
  gfx->setCursor((SCREEN_W - w) / 2, y);
  gfx->print(text);
}

// Draw text wrapped within maxWidth, centered horizontally
void drawWrappedText(const char* text, int y, int maxWidth, int size, uint16_t color) {
  gfx->setTextSize(size);
  gfx->setTextColor(color);

  String str = String(text);
  int charWidth = 6 * size; // Approximate character width
  int maxChars = maxWidth / charWidth;
  if (maxChars < 1) maxChars = 1;

  int lineHeight = 8 * size + 4;
  int currentY = y;

  while (str.length() > 0) {
    String line;
    if ((int)str.length() <= maxChars) {
      line = str;
      str = "";
    } else {
      // Find last space within maxChars
      int breakPoint = maxChars;
      for (int i = maxChars; i >= 0; i--) {
        if (str.charAt(i) == ' ') {
          breakPoint = i;
          break;
        }
      }
      line = str.substring(0, breakPoint);
      str = str.substring(breakPoint);
      str.trim();
    }

    int16_t x1, y1;
    uint16_t w, h;
    gfx->getTextBounds(line.c_str(), 0, 0, &x1, &y1, &w, &h);
    gfx->setCursor((SCREEN_W - w) / 2, currentY);
    gfx->print(line);
    currentY += lineHeight;
  }
}

// Draw a play triangle
void drawPlayIcon(int cx, int cy, int size, uint16_t color) {
  gfx->fillTriangle(
    cx - size/2, cy - size,
    cx - size/2, cy + size,
    cx + size, cy,
    color
  );
}

// Draw pause bars
void drawPauseIcon(int cx, int cy, int size, uint16_t color) {
  int barW = size / 2;
  int gap = size / 3;
  gfx->fillRect(cx - gap - barW, cy - size, barW, size * 2, color);
  gfx->fillRect(cx + gap, cy - size, barW, size * 2, color);
}

// Draw next track icon (triangle + line)
void drawNextIcon(int cx, int cy, int size, uint16_t color) {
  gfx->fillTriangle(
    cx - size, cy - size,
    cx - size, cy + size,
    cx + size/2, cy,
    color
  );
  gfx->fillRect(cx + size/2, cy - size, 3, size * 2, color);
}

// Draw prev track icon (line + triangle)
void drawPrevIcon(int cx, int cy, int size, uint16_t color) {
  gfx->fillRect(cx - size/2 - 3, cy - size, 3, size * 2, color);
  gfx->fillTriangle(
    cx + size, cy - size,
    cx + size, cy + size,
    cx - size/2, cy,
    color
  );
}

// Draw navigation arrow pointing in a direction
// angleDeg: 0 = straight ahead (up), 90 = right, -90 = left, 180 = u-turn
void drawNavArrow(int cx, int cy, float angleDeg, int arrowLen, uint16_t color) {
  float angleRad = angleDeg * PI / 180.0;

  // Arrow shaft endpoints (pointing up by default, rotated by angle)
  // "Up" on screen is negative Y
  float tipX = cx + sin(angleRad) * arrowLen;
  float tipY = cy - cos(angleRad) * arrowLen;
  float baseX = cx - sin(angleRad) * (arrowLen * 0.3);
  float baseY = cy + cos(angleRad) * (arrowLen * 0.3);

  // Arrowhead wings
  float wingAngle1 = angleRad + 2.5; // ~143 degrees offset
  float wingAngle2 = angleRad - 2.5;
  float wingLen = arrowLen * 0.4;
  float wing1X = tipX + sin(wingAngle1) * wingLen;
  float wing1Y = tipY - cos(wingAngle1) * wingLen;
  float wing2X = tipX + sin(wingAngle2) * wingLen;
  float wing2Y = tipY - cos(wingAngle2) * wingLen;

  // Draw thick arrow shaft
  for (int i = -2; i <= 2; i++) {
    gfx->drawLine(baseX + i, baseY, tipX + i, tipY, color);
    gfx->drawLine(baseX, baseY + i, tipX, tipY + i, color);
  }

  // Draw arrowhead
  gfx->fillTriangle(tipX, tipY, wing1X, wing1Y, wing2X, wing2Y, color);
}

// Draw small dots at bottom indicating current slide
void drawSlideIndicators() {
  int dotSpacing = 16;
  int startX = CENTER_X - (SLIDE_COUNT - 1) * dotSpacing / 2;
  int y = SCREEN_H - 20;

  for (int i = 0; i < SLIDE_COUNT; i++) {
    int x = startX + i * dotSpacing;
    if (i == (int)currentSlide) {
      gfx->fillCircle(x, y, 4, COLOR_INDICATOR_ACTIVE);
    } else {
      gfx->fillCircle(x, y, 3, COLOR_INDICATOR);
    }
  }
}

// ====== SLIDE DRAWING ======
void drawAnalogClock() {
  int cx = CENTER_X;
  int cy = CENTER_Y - 5;
  int radius = 95;

  // Clock face outline
  gfx->drawCircle(cx, cy, radius, 0x4208);
  gfx->drawCircle(cx, cy, radius - 1, 0x4208);

  // Hour markers
  for (int i = 0; i < 12; i++) {
    float angle = i * 30.0 * PI / 180.0;
    int innerR = (i % 3 == 0) ? radius - 15 : radius - 10;
    int outerR = radius - 3;
    int x1 = cx + sin(angle) * innerR;
    int y1 = cy - cos(angle) * innerR;
    int x2 = cx + sin(angle) * outerR;
    int y2 = cy - cos(angle) * outerR;
    uint16_t markerColor = (i % 3 == 0) ? WHITE : 0x7BEF;
    gfx->drawLine(x1, y1, x2, y2, markerColor);
    if (i % 3 == 0) {
      gfx->drawLine(x1 + 1, y1, x2 + 1, y2, markerColor);
    }
  }

  // Hour hand
  float hourAngle = ((hours % 12) + minutes / 60.0) * 30.0 * PI / 180.0;
  int hLen = 50;
  for (int d = -2; d <= 2; d++) {
    gfx->drawLine(cx + d, cy, cx + sin(hourAngle) * hLen + d, cy - cos(hourAngle) * hLen, COLOR_TIME);
    gfx->drawLine(cx, cy + d, cx + sin(hourAngle) * hLen, cy - cos(hourAngle) * hLen + d, COLOR_TIME);
  }

  // Minute hand
  float minAngle = (minutes + seconds / 60.0) * 6.0 * PI / 180.0;
  int mLen = 72;
  for (int d = -1; d <= 1; d++) {
    gfx->drawLine(cx + d, cy, cx + sin(minAngle) * mLen + d, cy - cos(minAngle) * mLen, WHITE);
    gfx->drawLine(cx, cy + d, cx + sin(minAngle) * mLen, cy - cos(minAngle) * mLen + d, WHITE);
  }

  // Second hand (thin, colored)
  float secAngle = seconds * 6.0 * PI / 180.0;
  int sLen = 80;
  gfx->drawLine(cx, cy, cx + sin(secAngle) * sLen, cy - cos(secAngle) * sLen, COLOR_TIME_SEC);

  // Center dot
  gfx->fillCircle(cx, cy, 4, COLOR_TIME);
}

void drawTimeSlide() {
  gfx->fillScreen(COLOR_BG);

  if (!timeInitialized) {
    drawCenteredText("Waiting for", CENTER_Y - 20, 2, WHITE);
    drawCenteredText("time sync...", CENTER_Y + 10, 2, WHITE);
  } else if (analogClock) {
    drawAnalogClock();
  } else {
    // Digital clock
    char timeStr[6];
    sprintf(timeStr, "%02d:%02d", hours, minutes);
    drawCenteredText(timeStr, CENTER_Y - 30, 5, COLOR_TIME);

    char secStr[4];
    sprintf(secStr, ":%02d", seconds);
    drawCenteredText(secStr, CENTER_Y + 30, 3, COLOR_TIME_SEC);
  }

  // Connection indicator
  if (deviceConnected) {
    gfx->fillCircle(CENTER_X, 25, 5, COLOR_TIME);
  } else {
    gfx->drawCircle(CENTER_X, 25, 5, 0x4208);
  }

  drawSlideIndicators();
}

void drawMusicSlide() {
  gfx->fillScreen(COLOR_MUSIC_BG);

  if (!musicDataReceived) {
    drawCenteredText("No music", CENTER_Y - 20, 2, 0x4208);
    drawCenteredText("playing", CENTER_Y + 5, 2, 0x4208);
  } else {
    // Music icon / state at top
    if (musicState == "PLAYING") {
      // Draw equalizer-style bars
      for (int i = 0; i < 3; i++) {
        int barH = 8 + (i % 2) * 8;
        gfx->fillRect(CENTER_X - 15 + i * 12, 35 - barH, 8, barH, COLOR_MUSIC_ICON);
      }
    } else if (musicState == "PAUSED") {
      drawPauseIcon(CENTER_X, 28, 8, 0x7BEF); // Gray
    } else {
      gfx->fillRect(CENTER_X - 8, 20, 16, 16, 0x4208); // Stop square
    }

    // Title (larger, white)
    if (musicTitle.length() > 0) {
      drawWrappedText(musicTitle.c_str(), CENTER_Y - 35, 200, 2, COLOR_MUSIC_TITLE);
    }

    // Artist (smaller, cyan)
    if (musicArtist.length() > 0) {
      drawWrappedText(musicArtist.c_str(), CENTER_Y + 20, 200, 2, COLOR_MUSIC_ARTIST);
    }

    // Transport controls at bottom - large touch targets for glove use
    int controlY = SCREEN_H - 55;

    // Draw large touch zone circles for glove visibility
    gfx->drawCircle(CENTER_X - 55, controlY, 30, 0x2104);
    gfx->drawCircle(CENTER_X, controlY, 32, 0x2104);
    gfx->drawCircle(CENTER_X + 55, controlY, 30, 0x2104);

    // Draw larger control icons
    drawPrevIcon(CENTER_X - 55, controlY, 12, 0x7BEF);

    if (musicState == "PLAYING") {
      drawPauseIcon(CENTER_X, controlY, 14, COLOR_MUSIC_ICON);
    } else {
      drawPlayIcon(CENTER_X, controlY, 14, COLOR_MUSIC_ICON);
    }

    drawNextIcon(CENTER_X + 55, controlY, 12, 0x7BEF);
  }

  drawSlideIndicators();
}

void drawNavSlide() {
  gfx->fillScreen(COLOR_NAV_BG);

  if (!navDataReceived) {
    drawCenteredText("No navigation", CENTER_Y - 20, 2, 0x4208);
    drawCenteredText("active", CENTER_Y + 5, 2, 0x4208);
  } else {
    // Direction arrow (large, centered)
    drawNavArrow(CENTER_X, CENTER_Y - 15, navDirection, 55, COLOR_NAV_ARROW);

    // Distance at top
    char distStr[32];
    snprintf(distStr, sizeof(distStr), "%s %s", navDistance.c_str(), navUnit.c_str());
    drawCenteredText(distStr, 30, 3, COLOR_NAV_DIST);

    // Instruction at bottom
    if (navInstruction.length() > 0) {
      drawWrappedText(navInstruction.c_str(), SCREEN_H - 70, 200, 2, COLOR_NAV_INST);
    }
  }

  drawSlideIndicators();
}

void drawSlide() {
  switch (currentSlide) {
    case SLIDE_TIME:  drawTimeSlide();  break;
    case SLIDE_MUSIC: drawMusicSlide(); break;
    case SLIDE_NAV:   drawNavSlide();   break;
    default: break;
  }
  slideNeedsRedraw = false;
}

// ====== SETUP ======
void setup() {
  Serial.begin(115200);

  // Backlight (Arduino ESP32 core 3.x API)
  ledcAttach(TFT_BL, 5000, 8);
  ledcWrite(TFT_BL, 255);

  // Display
  if (!gfx->begin()) {
    Serial.println("Display init failed!");
    while (1);
  }

  gfx->fillScreen(BLACK);
  drawCenteredText("MC Display", CENTER_Y - 30, 2, WHITE);
  drawCenteredText("BLE Ready...", CENTER_Y, 2, 0x07E0);
  drawCenteredText("Waiting for phone", CENTER_Y + 25, 1, 0x4208);

  // Initialize touch
  touchInit();

  // BLE init
  BLEDevice::init("ESP32S3_Display");

  BLESecurity *pSecurity = new BLESecurity();
  pSecurity->setAuthenticationMode(ESP_LE_AUTH_BOND);
  pSecurity->setCapability(ESP_IO_CAP_NONE);
  pSecurity->setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pTxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_TX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pTxCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_RX,
    BLECharacteristic::PROPERTY_WRITE
  );
  pRxCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();
  pServer->getAdvertising()->start();

  Serial.println("BLE service started. Connect from phone.");

  // Show time slide initially
  delay(2000);
  slideNeedsRedraw = true;
}

// ====== LOOP ======
void loop() {
  unsigned long currentMillis = millis();

  // Update time every second
  if (currentMillis - lastSecondMillis >= 1000) {
    lastSecondMillis = currentMillis;

    if (timeInitialized) {
      incrementTime();
      // Only redraw if we're on the time slide
      if (currentSlide == SLIDE_TIME) {
        slideNeedsRedraw = true;
      }
    }
  }

  // Handle touch input
  handleTouch();

  // Auto-slide switching
  if (autoSlideEnabled && SLIDE_AUTO_SWITCH_MS > 0) {
    if (currentMillis - lastSlideSwitch >= SLIDE_AUTO_SWITCH_MS) {
      lastSlideSwitch = currentMillis;
      currentSlide = (Slide)((currentSlide + 1) % SLIDE_COUNT);
      slideNeedsRedraw = true;
    }
  }

  // Redraw slide if needed
  if (slideNeedsRedraw) {
    drawSlide();
  }

  delay(10); // Small delay to prevent watchdog issues
}
