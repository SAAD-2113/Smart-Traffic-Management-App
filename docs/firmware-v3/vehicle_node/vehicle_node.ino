// ============================================================================
//  V2I Smart Traffic - VEHICLE UNIT  (ESP32-S3 / ESP32 / ESP8266 - same sketch)
//
//  WHAT IT DOES
//  - No GPS module in the demo: the vehicle generates its own TEST DATA
//    (lat, lon, speed, heading) for one arm of the junction, with small noise.
//  - Sends one UDP JSON packet to the intersection every 500 ms (< 200 bytes).
//  - The INTERSECTION decides lane and state from lat/lon/spd/hdg. The "tl"
//    field (test lane) is sent only so the intersection can print [MISMATCH]
//    if its own decision disagrees with the test data.
//  - Obeys the ACK: brakes and stops at its queue slot on red/yellow, drives on
//    green, crosses, leaves, pauses, restarts. No ACK for 3 s => treated as RED.
//  - Serial Monitor (115200): [TX] each packet, [ACK] each reply, [BASIS] the
//    numbers the intersection's decision is based on and the lane/state it
//    should compute from them (same v2iClassify() function as the intersection).
//
//  HOW TO USE
//  - Set BOARD_PRESET (1..6) below, pick the board type, upload.
//      1: id101 normal    lane N, slot 0      4: id104 normal    lane E
//      2: id102 normal    lane N, slot 1      5: id201 EMERGENCY lane W, starts after 30 s
//      3: id103 normal    lane N, slot 2      6: id202 EMERGENCY lane S, starts after 70 s
//    Presets 1-3 deliberately make lane N the dense lane.
//    BOARD_PRESET 0 = use the MANUAL_* values.
//  - TEST_SOURCE: 0 = motion simulation (default), 1 = replay the REPLAY[] table.
//
//  Libraries: ArduinoJson v7. ESP32-S3 on its native USB port: Tools ->
//  "USB CDC On Boot" = Enabled, otherwise the Serial Monitor stays empty.
// ============================================================================
#include <Arduino.h>                 // defines ESP8266 / CONFIG_IDF_TARGET_ESP32S3 for the tests below
#if defined(ESP8266)
  #include <ESP8266WiFi.h>
  #define HW_NAME "ESP8266"
#else
  #include <WiFi.h>
  #if defined(CONFIG_IDF_TARGET_ESP32S3)
    #define HW_NAME "ESP32-S3"
  #else
    #define HW_NAME "ESP32"
  #endif
#endif
#include <WiFiUdp.h>
#include <ArduinoJson.h>
#include "v2i_common.h"

// ----------------------------- 1. Which vehicle is this board? --------------
#ifndef BOARD_PRESET
#define BOARD_PRESET        1      // 1..6 = demo vehicles, 0 = MANUAL_* values below
#endif

// Used only when BOARD_PRESET = 0
#define MANUAL_ID           105
#define MANUAL_TYPE         VT_NORMAL   // VT_NORMAL or VT_EMERGENCY
#define MANUAL_ARM          2           // 0=N 1=E 2=S 3=W (arm it approaches from)
#define MANUAL_SLOT         0           // queue position when stopped: 0 = front, 1, 2, ...
#define MANUAL_START_DIST_M 120.0f      // start distance from centre (keep below 150)
#define MANUAL_CRUISE_KMH   30.0f
#define MANUAL_DELAY_S      0           // wait this long (parked out of range) before driving in

#if BOARD_PRESET < 0 || BOARD_PRESET > 6
  #error "BOARD_PRESET must be 0..6"
#endif

struct Preset { uint16_t id; uint8_t type; uint8_t arm; uint8_t slot; float startDist; float kmh; uint16_t delayS; };
const Preset PRESETS[6] = {
  //  id   type          arm slot dist    km/h delay
  { 101, VT_NORMAL,      0,  0,  100.0f, 30,   0 },   // 1  N lane, front of queue
  { 102, VT_NORMAL,      0,  1,  115.0f, 30,   0 },   // 2  N lane, 2nd in queue
  { 103, VT_NORMAL,      0,  2,  130.0f, 30,   0 },   // 3  N lane, 3rd in queue
  { 104, VT_NORMAL,      1,  0,  110.0f, 30,   0 },   // 4  E lane
  { 201, VT_EMERGENCY,   3,  0,  140.0f, 50,  30 },   // 5  W lane, emergency, starts after 30 s
  { 202, VT_EMERGENCY,   2,  0,  140.0f, 50,  70 },   // 6  S lane, emergency, starts after 70 s
};

// ----------------------------- 2. Test-data source --------------------------
#ifndef TEST_SOURCE
#define TEST_SOURCE         0      // 0 = motion simulation, 1 = replay REPLAY[] table
#endif
#define LOOP_TRIP           1      // restart the trip after it finishes

// ----------------------------- 3. Timing / behaviour constants --------------
#define BEACON_MS           500    // one packet every 500 ms
#define SIM_STEP_MS         100
#define STOP_LINE_M         12.0f  // stop line distance from centre. Must stay outside JUNCTION_R_M
                                   // (+ noise) or a stopped front vehicle flickers into CROSSING
#define QUEUE_SPACING_M     6.0f   // gap between stopped vehicles (slot spacing)
#define ACCEL_MS2           2.0f
#define DECEL_MS2           3.0f   // normal braking (used to plan the stop)
#define MAX_DECEL_MS2       6.0f   // hardest braking allowed to hold the stop point
#define DEPART_END_M        80.0f  // trip ends this far past the centre
#define PARK_DIST_M         400.0f // where a delayed vehicle waits (outside detection range)
#define RESTART_DELAY_MS    15000  // pause after a finished trip
#define ACK_TIMEOUT_MS      3000   // no ACK for this long => treat signal as RED
#define REPLAY_INTERVAL_MS  500    // one table row per packet
#define WIFI_RETRY_MS       5000   // re-try joining the AP this often while disconnected
#define LOG_BASIS           1      // 1 = print the [BASIS] line after every [TX]

// Test-data imperfections (simulated GPS noise)
#define GPS_NOISE_M         1.0f   // +-1 m position jitter
#define HDG_NOISE_DEG       2.0f   // +-2 deg heading jitter
#define SPD_NOISE_KMH       0.4f   // +-0.4 km/h speed jitter

static_assert(STOP_LINE_M >= JUNCTION_R_M + 2.0f * GPS_NOISE_M,
              "STOP_LINE_M too close to the junction box: queued vehicles would read as CROSSING");

#if TEST_SOURCE == 1
// Fixed table of test points { lat, lon, speed_kmh, heading_deg }.
// Sample: approach on the NORTH arm, stop in the queue zone, cross, leave south.
// (Set BOARD_PRESET to an N-lane vehicle, or edit the rows, so "tl" matches.)
struct TestPt { double lat, lon; float spd, hdg; };
const TestPt REPLAY[] = {
  {31.501078, 74.300000, 30.0, 180},   // 120 m N, approaching
  {31.500943, 74.300000, 30.0, 180},   // 105 m
  {31.500808, 74.300000, 28.0, 180},   //  90 m
  {31.500674, 74.300000, 22.0, 180},   //  75 m
  {31.500539, 74.300000, 15.0, 180},   //  60 m
  {31.500404, 74.300000,  8.0, 180},   //  45 m
  {31.500269, 74.300000,  3.0, 180},   //  30 m  -> QUEUED (slow, inside 60 m)
  {31.500180, 74.300000,  0.0, 180},   //  20 m  QUEUED
  {31.500180, 74.300000,  0.0, 180},   //  20 m  QUEUED
  {31.500180, 74.300000,  0.0, 180},   //  20 m  QUEUED
  {31.500135, 74.300000, 10.0, 180},   //  15 m  APPROACHING again (moving)
  {31.500045, 74.300000, 18.0, 180},   //   5 m  CROSSING
  {31.499955, 74.300000, 22.0, 180},   //  -5 m  CROSSING
  {31.499820, 74.300000, 28.0, 180},   // -20 m  IGNORED (leaving)
  {31.499551, 74.300000, 30.0, 180},   // -50 m  IGNORED (leaving)
};
const int REPLAY_LEN = sizeof(REPLAY) / sizeof(REPLAY[0]);
#endif

// ----------------------------- State ----------------------------------------
WiFiUDP   udp;
IPAddress intersectionIP;
bool      wifiWasUp = false;

uint16_t vId = 0;
uint8_t  vType = VT_NORMAL, vArm = 0, vSlot = 0;
float    vStartDist = 100, vCruise = 8.3f;      // vCruise in m/s
uint32_t vDelayMs = 0;

// transmitted pose = the test-data fix
double poseLat = CENTER_LAT, poseLon = CENTER_LON;
float  poseSpdKmh = 0, poseHdg = 0;

// simulation state
float    simS = 100;            // metres from centre along the arm (negative = past the centre)
float    simV = 0;              // m/s
bool     parked = false, tripDone = false;
bool     committed = false;      // passed the stop line on green / unavoidable yellow
uint32_t departAt = 0, tripDoneAt = 0;
const char* action = "START";
int      replayIdx = 0;

// last ACK from the intersection
char     ackLane[4] = "-", ackSt[16] = "-", ackMode[12] = "-";
char     ackSig = 'R';
float    ackRem = 0;
int      ackPri = 0;
uint32_t lastAckMs = 0, seqNo = 0, acksRx = 0;
uint32_t detectMs = 0;          // when the intersection first gave this vehicle a lane
bool     prioReported = false;
int      basisPrevLane = -1;    // previous lane of the local [BASIS] check

// ----------------------------- Helpers --------------------------------------
#if TEST_SOURCE == 0
static float noise(float amp) { return amp * ((int)random(-1000, 1001)) / 1000.0f; }
#endif

void loadConfig() {
#if BOARD_PRESET > 0
  const Preset &p = PRESETS[BOARD_PRESET - 1];
  vId = p.id; vType = p.type; vArm = p.arm; vSlot = p.slot;
  vStartDist = p.startDist; vCruise = p.kmh / 3.6f; vDelayMs = (uint32_t)p.delayS * 1000UL;
#else
  vId = MANUAL_ID; vType = MANUAL_TYPE; vArm = MANUAL_ARM; vSlot = MANUAL_SLOT;
  vStartDist = MANUAL_START_DIST_M; vCruise = MANUAL_CRUISE_KMH / 3.6f;
  vDelayMs = (uint32_t)MANUAL_DELAY_S * 1000UL;
#endif
}

char effectiveSignal() {
  if (lastAckMs == 0 || millis() - lastAckMs > ACK_TIMEOUT_MS) return 'R';   // no link -> be safe
  return ackSig;
}

// ----------------------------- Wi-Fi (non-blocking, auto-reconnect) ---------
void wifiStart() {
  WiFi.mode(WIFI_STA);
#if defined(ESP8266)
  WiFi.persistent(false);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);
#else
  WiFi.setSleep(false);                 // lowest latency for ACKs
#endif
  WiFi.setAutoReconnect(true);
  WiFi.begin(AP_SSID, AP_PASS, AP_CHANNEL);
  Serial.printf("[WIFI] joining %s (channel %d) ...\n", AP_SSID, AP_CHANNEL);
}

void wifiEnsure() {
  static uint32_t lastTry = 0;
  bool up = (WiFi.status() == WL_CONNECTED);
  if (up && !wifiWasUp) {
    Serial.printf("[WIFI] connected  IP=%s  RSSI=%d dBm\n", WiFi.localIP().toString().c_str(), (int)WiFi.RSSI());
    udp.stop();
    udp.begin(VEHICLE_ACK_PORT);        // (re)open the ACK port on the new link
  }
  if (!up && wifiWasUp) Serial.println("[WIFI] link lost - reconnecting (signal treated as RED after 3 s)");
  wifiWasUp = up;
  if (up) return;
  if (millis() - lastTry < WIFI_RETRY_MS) return;
  lastTry = millis();
  Serial.printf("[WIFI] not connected (status %d) - retrying %s\n", (int)WiFi.status(), AP_SSID);
  WiFi.disconnect();
  WiFi.begin(AP_SSID, AP_PASS, AP_CHANNEL);
}

// ----------------------------- Motion simulation ----------------------------
void restartTrip(bool first) {
  tripDone = false; replayIdx = 0; lastAckMs = 0; committed = false;
  detectMs = 0; prioReported = false; basisPrevLane = -1;
  if (first && vDelayMs > 0) {
    parked = true; departAt = millis() + vDelayMs; simS = PARK_DIST_M; simV = 0; action = "PARKED";
    Serial.printf("[SIM ] parked %.0f m out (outside detection range), departs in %lu s\n",
                  PARK_DIST_M, (unsigned long)(vDelayMs / 1000));
  } else {
    parked = false; simS = vStartDist; simV = vCruise; action = "START";
    Serial.printf("[SIM ] trip started %.0f m out on arm %s\n", vStartDist, LANE_NAME[vArm]);
  }
}

void simStep(float dt) {
  if (tripDone) return;

  if (parked) {
    if ((int32_t)(millis() - departAt) < 0) { simS = PARK_DIST_M; simV = 0; action = "PARKED"; return; }
    parked = false; simS = vStartDist; simV = vCruise; lastAckMs = 0;
    Serial.println("[SIM ] departing - entering the junction detection area");
  }

  float stopSlot = STOP_LINE_M + vSlot * QUEUE_SPACING_M;

  if (committed) {                                   // past the stop line: clear the junction
    simV = min(vCruise, simV + ACCEL_MS2 * dt);
    simS -= simV * dt;
    action = (simS > 0) ? "CROSSING" : "DEPARTING";
  } else {
    char  sig    = effectiveSignal();
    float stopAt = (simS > stopSlot + 0.05f) ? stopSlot : STOP_LINE_M;  // own queue slot first, then the line
    float dStop  = max(0.0f, simS - stopAt);
    bool  mustStop = (sig != 'G');
    if (sig == 'Y') {
      float brakeDist = (simV * simV) / (2.0f * DECEL_MS2);
      if (simS - STOP_LINE_M < brakeDist - 0.5f) mustStop = false;      // too close to stop safely: clear it
    }
    if (!mustStop) {
      simV = min(vCruise, simV + ACCEL_MS2 * dt);
      action = (sig == 'Y') ? "RUN-YELLOW" : (simV < vCruise * 0.9f ? "ACCEL" : "CRUISE");
      simS -= simV * dt;
    } else {
      float vAllowed = sqrtf(2.0f * DECEL_MS2 * dStop);                  // fastest speed that can still stop
      if (simV > vAllowed) { simV = max(vAllowed, simV - MAX_DECEL_MS2 * dt); action = "BRAKING"; }
      else                 { simV = min(min(vCruise, vAllowed), simV + ACCEL_MS2 * dt); action = "APPROACH-RED"; }
      simS -= simV * dt;
      if (simS <= stopAt) { simS = stopAt; simV = 0; }                  // never pass the stop point on red
      if (simV < 0.3f) action = "STOPPED";
    }
    if (simS < STOP_LINE_M) committed = true;                            // only reachable on G / run-yellow
  }

  if (simS <= -DEPART_END_M) {
    tripDone = true; tripDoneAt = millis(); simV = 0; action = "FINISHED";
    Serial.printf("[SIM ] trip finished - restarting in %lu s\n", (unsigned long)(RESTART_DELAY_MS / 1000));
  }
}

// Builds the test-data fix that is transmitted
void updatePose() {
#if TEST_SOURCE == 1
  const TestPt &p = REPLAY[replayIdx];
  poseLat = p.lat; poseLon = p.lon; poseSpdKmh = p.spd; poseHdg = p.hdg;
  action = "REPLAY";
  if (++replayIdx >= REPLAY_LEN) replayIdx = 0;
#else
  float  brg = ARM_BEARING[vArm] * (float)M_PI / 180.0f;
  double x = simS * sin(brg) + noise(GPS_NOISE_M);                  // metres east of centre
  double y = simS * cos(brg) + noise(GPS_NOISE_M);                  // metres north of centre
  xyToLatLon(x, y, poseLat, poseLon);
  poseSpdKmh = max(0.0f, simV * 3.6f + noise(SPD_NOISE_KMH));
  poseHdg    = wrap360(ARM_BEARING[vArm] + 180.0f + noise(HDG_NOISE_DEG));   // driving toward the centre
#endif
}

// ----------------------------- V2I link -------------------------------------
void sendBeacon() {
  // Round exactly as transmitted, so [BASIS] uses the same numbers the intersection gets
  double txLat = round(poseLat * 1e6) / 1e6;
  double txLon = round(poseLon * 1e6) / 1e6;
  float  txSpd = roundf(poseSpdKmh * 10.0f) / 10.0f;
  int    txHdg = ((int)lroundf(poseHdg)) % 360;
  int    rssi  = (int)WiFi.RSSI();

  char buf[V2I_MAX_PACKET];
  int n = snprintf(buf, sizeof(buf),
      "{\"t\":\"pos\",\"id\":%u,\"ty\":%u,\"lat\":%.6f,\"lon\":%.6f,\"spd\":%.1f,\"hdg\":%d,"
      "\"seq\":%lu,\"hw\":\"%s\",\"tl\":\"%s\",\"rssi\":%d}",
      (unsigned)vId, (unsigned)vType, txLat, txLon, txSpd, txHdg,
      (unsigned long)seqNo, HW_NAME, LANE_NAME[vArm], rssi);
  if (n <= 0 || n >= (int)sizeof(buf)) { Serial.println("[TX! ] packet too long - not sent"); return; }

  udp.beginPacket(intersectionIP, V2I_UDP_PORT);
  udp.write((const uint8_t *)buf, n);
  udp.endPacket();

  Serial.printf("[TX  ] #%lu id=%u %s %s lat=%.6f lon=%.6f spd=%.1f hdg=%d tl=%s rssi=%d (%d B) | sig=%c %s\n",
                (unsigned long)seqNo, (unsigned)vId, vType == VT_EMERGENCY ? "EMERG" : "normal",
                HW_NAME, txLat, txLon, txSpd, txHdg, LANE_NAME[vArm], rssi, n,
                effectiveSignal(), action);

#if LOG_BASIS
  V2IDecision b = v2iClassify(txLat, txLon, txSpd, (float)txHdg, true, basisPrevLane, 1e9f);
  basisPrevLane = b.lane;
  Serial.printf("[BASIS] bearing=%.0fdeg dist=%.1fm hdg=%ddeg spd=%.1fkm/h => expect lane %s, %s%s%s%s\n",
                b.bearing, b.dist, txHdg, txSpd, b.lane >= 0 ? LANE_NAME[b.lane] : "-", stateName(b.st),
                b.st == ST_IGNORED ? " (" : "", b.st == ST_IGNORED ? reasonName(b.reason) : "",
                b.st == ST_IGNORED ? ")" : (b.st == ST_QUEUED ? "  -> counts in Qw" : ""));
#endif
  seqNo++;
}

void receiveAck() {
  int len;
  while ((len = udp.parsePacket()) > 0) {
    char buf[256];
    int n = udp.read(buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = 0;
    JsonDocument d;
    if (deserializeJson(d, buf) || strcmp(d["t"] | "", "ack") != 0) continue;
    if ((int)(d["id"] | 0) != (int)vId) continue;

    strlcpy(ackLane, d["lane"] | "-", sizeof(ackLane));
    strlcpy(ackSt,   d["st"]   | "-", sizeof(ackSt));
    strlcpy(ackMode, d["mode"] | "-", sizeof(ackMode));
    const char *sg = d["sig"] | "R";
    ackSig = (sg[0] == 'G' || sg[0] == 'Y') ? sg[0] : 'R';
    ackRem = d["rem"] | 0.0f;
    ackPri = d["pri"] | 0;
    lastAckMs = millis();
    acksRx++;
    Serial.printf("[ACK ] seq=%lu lane=%s st=%s sig=%s rem=%.1fs mode=%s%s\n",
                  (unsigned long)(d["seq"] | 0UL), ackLane, ackSt, sg, ackRem, ackMode,
                  ackPri ? " PRIORITY" : "");

    // Emergency vehicle: report how long the intersection took to give it green
    bool hasLane = strcmp(ackLane, "-") != 0;
    if (hasLane && detectMs == 0) detectMs = millis();
    if (vType == VT_EMERGENCY && hasLane && ackSig == 'G' && !prioReported) {
      prioReported = true;
      Serial.printf("[PRIO] GREEN on lane %s, %.1f s after the intersection first assigned this vehicle a lane\n",
                    ackLane, (millis() - detectMs) / 1000.0f);
    }
  }
}

// ============================================================================
void setup() {
  Serial.begin(115200);
  delay(300);                                          // short, once, at boot
  loadConfig();
  randomSeed((uint32_t)vId * 7919UL + micros());

  Serial.println();
  Serial.printf("=== V2I VEHICLE UNIT (%s) preset=%d id=%u type=%s lane=%s slot=%u start=%.0fm speed=%.0fkm/h source=%s ===\n",
                HW_NAME, BOARD_PRESET, vId, vType == VT_EMERGENCY ? "EMERGENCY" : "normal",
                LANE_NAME[vArm], vSlot, vStartDist, vCruise * 3.6f,
                TEST_SOURCE == 1 ? "REPLAY table" : "motion simulation");
  intersectionIP.fromString(INTERSECTION_IP_STR);
  wifiStart();
  restartTrip(true);
#if TEST_SOURCE == 0
  updatePose();                                        // replay mode starts at row 0 in loop()
#endif
}

void loop() {
  static uint32_t tSim = millis(), tBeacon = 0, tReplay = 0;
  uint32_t now = millis();

  wifiEnsure();
  if (WiFi.status() == WL_CONNECTED) receiveAck();

#if TEST_SOURCE == 1
  if (now - tReplay >= REPLAY_INTERVAL_MS) { tReplay = now; updatePose(); }
  (void)tSim;
#else
  if (now - tSim >= SIM_STEP_MS) {
    float dt = (now - tSim) / 1000.0f;
    tSim = now;
    simStep(dt);
    updatePose();
  }
  if (tripDone && LOOP_TRIP && now - tripDoneAt > RESTART_DELAY_MS) restartTrip(false);
  (void)tReplay;
#endif

  if (now - tBeacon >= BEACON_MS && WiFi.status() == WL_CONNECTED) {
    tBeacon = now;
    sendBeacon();
  }
  delay(1);                                            // yield to the Wi-Fi stack (1 ms)
}
