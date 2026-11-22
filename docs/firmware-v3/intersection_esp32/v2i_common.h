// ============================================================================
//  v2i_common.h  -  shared by intersection_esp32.ino AND vehicle_node.ino
//  Copy this IDENTICAL file into both sketch folders.
//
//  Holds everything both sides must agree on:
//    - Wi-Fi / UDP settings
//    - junction centre used by the TEST DATA (no GPS module in the demo)
//    - lane names and arm bearings
//    - lane-decision thresholds + the lane-decision function itself
//      (the intersection uses it to DECIDE; the vehicle uses the very same
//       function only to PRINT its [BASIS] line, so the two can never drift)
// ============================================================================
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

// ---------------- Network (intersection ESP32 is the Wi-Fi access point) ----
#define AP_SSID              "V2I-Junction-01"
#define AP_PASS              "v2i12345"          // >= 8 chars
#define AP_CHANNEL           6
#define INTERSECTION_IP_STR  "192.168.4.1"       // set explicitly with softAPConfig()
#define V2I_UDP_PORT         4210                // vehicles -> intersection
#define VEHICLE_ACK_PORT     4211                // local port on each vehicle (ACKs come back here)
#define V2I_MAX_PACKET       200                 // every UDP packet must be shorter than this

// ---------------- Junction geometry (TEST DATA origin) -----------------------
#define CENTER_LAT   31.500000
#define CENTER_LON   74.300000

#define NUM_LANES    4                           // one lane per arm: N, E, S, W
static const char* const LANE_NAME[NUM_LANES]   = {"N", "E", "S", "W"};
// Bearing from the junction centre OUT along each arm (0 = north, clockwise).
static const float       ARM_BEARING[NUM_LANES] = {0.0f, 90.0f, 180.0f, 270.0f};

// ---------------- Vehicle types ----------------------------------------------
#define VT_NORMAL      0
#define VT_EMERGENCY   1

// ---------------- Lane-decision thresholds (one source of truth) -------------
#define DETECT_RADIUS_M      150.0f   // farther than this            -> IGNORED
#define JUNCTION_R_M         10.0f    // closer than this             -> CROSSING (keeps previous lane)
#define QUEUE_ZONE_M         60.0f    // within this AND slow         -> QUEUED
#define QUEUE_SPEED_KMH      5.0f     // "slow" means below this speed
#define ARM_HALF_ANGLE_DEG   45.0f    // bearing must be within +-45 deg of an arm
#define HEADING_TOL_DEG      60.0f    // heading must point at the centre within +-60 deg

// ---------------- Geometry helpers --------------------------------------------
#define M_PER_DEG_LAT 111320.0
static inline double mPerDegLon() { return 111320.0 * cos(CENTER_LAT * M_PI / 180.0); }

static inline void latlonToXY(double lat, double lon, double &x, double &y) {
  x = (lon - CENTER_LON) * mPerDegLon();     // metres east of centre
  y = (lat - CENTER_LAT) * M_PER_DEG_LAT;    // metres north of centre
}
static inline void xyToLatLon(double x, double y, double &lat, double &lon) {
  lon = CENTER_LON + x / mPerDegLon();
  lat = CENTER_LAT + y / M_PER_DEG_LAT;
}
// smallest absolute angle between two bearings (degrees, 0..180)
static inline float angDiff(float a, float b) {
  float d = fmodf(a - b + 540.0f, 360.0f) - 180.0f;
  return fabsf(d);
}
static inline float wrap360(float a) {
  a = fmodf(a, 360.0f);
  return a < 0 ? a + 360.0f : a;
}
static inline int laneIndex(const char *name) {           // "N" -> 0 ... ; -1 if unknown
  if (!name) return -1;
  for (int i = 0; i < NUM_LANES; i++) if (!strcmp(name, LANE_NAME[i])) return i;
  return -1;
}

// ---------------- Lane decision ------------------------------------------------
enum V2IState  : uint8_t { ST_APPROACHING, ST_QUEUED, ST_CROSSING, ST_IGNORED };
enum V2IReason : uint8_t { RS_OK, RS_OUT_OF_RANGE, RS_OFF_ARM, RS_HEADING_AWAY, RS_IN_BOX_NO_LANE };

static inline const char* stateName(uint8_t s) {
  switch (s) {
    case ST_APPROACHING: return "APPROACHING";
    case ST_QUEUED:      return "QUEUED";
    case ST_CROSSING:    return "CROSSING";
    default:             return "IGNORED";
  }
}
static inline const char* reasonName(uint8_t r) {
  switch (r) {
    case RS_OUT_OF_RANGE:   return "out of range";
    case RS_OFF_ARM:        return "not on any arm";
    case RS_HEADING_AWAY:   return "heading away / leaving";
    case RS_IN_BOX_NO_LANE: return "inside box, no previous lane";
    default:                return "";
  }
}

struct V2IDecision {
  int8_t  lane;      // 0..3 or -1
  uint8_t st;        // V2IState
  uint8_t reason;    // V2IReason (why IGNORED)
  float   dist;      // metres from centre
  float   bearing;   // centre -> vehicle, degrees
};

// Decides lane + state from position, speed and heading ONLY.
//   prevLane : lane decided from this vehicle's previous packet (-1 if none)
//   hdgValid : false if the sender gave no heading -> fall back to "getting closer"
//   prevDist : distance at the previous packet (only used when hdgValid == false)
static inline V2IDecision v2iClassify(double lat, double lon, float spdKmh, float hdgDeg,
                                      bool hdgValid, int prevLane, float prevDist) {
  V2IDecision r;
  double x, y;
  latlonToXY(lat, lon, x, y);
  r.dist    = (float)sqrt(x * x + y * y);
  r.bearing = wrap360((float)(atan2(x, y) * 180.0 / M_PI));
  r.lane = -1; r.st = ST_IGNORED; r.reason = RS_OK;

  if (r.dist > DETECT_RADIUS_M) { r.reason = RS_OUT_OF_RANGE; return r; }

  if (r.dist < JUNCTION_R_M) {                               // inside the junction box
    if (prevLane >= 0) { r.lane = (int8_t)prevLane; r.st = ST_CROSSING; }
    else r.reason = RS_IN_BOX_NO_LANE;
    return r;
  }

  int arm = -1; float best = 999.0f;                         // nearest arm within +-45 deg
  for (int i = 0; i < NUM_LANES; i++) {
    float d = angDiff(r.bearing, ARM_BEARING[i]);
    if (d <= ARM_HALF_ANGLE_DEG && d < best) { best = d; arm = i; }
  }
  if (arm < 0) { r.reason = RS_OFF_ARM; return r; }

  bool inbound = hdgValid
      ? (angDiff(hdgDeg, wrap360(ARM_BEARING[arm] + 180.0f)) <= HEADING_TOL_DEG)
      : (r.dist < prevDist + 0.5f);
  if (!inbound) { r.reason = RS_HEADING_AWAY; return r; }

  r.lane = (int8_t)arm;
  r.st   = (spdKmh < QUEUE_SPEED_KMH && r.dist <= QUEUE_ZONE_M) ? ST_QUEUED : ST_APPROACHING;
  return r;
}

// ============================================================================
//  PACKET FORMATS (JSON over UDP, one datagram each, < 200 bytes)
//
//  Vehicle -> Intersection  (every 500 ms)
//    {"t":"pos","id":101,"ty":0,"lat":31.500808,"lon":74.300000,"spd":29.8,
//     "hdg":180,"seq":42,"hw":"ESP32-S3","tl":"N","rssi":-52}
//      ty  : 0 normal, 1 emergency       spd : km/h      hdg : degrees (0 = N)
//      seq : packet counter (gaps = lost packets)
//      tl  : lane according to the TEST DATA. Used ONLY to check the
//            intersection's own decision ([MISMATCH]); never to make it.
//      rssi: WiFi.RSSI() of the vehicle, dBm
//
//  Intersection -> Vehicle  (reply to every "pos", to the sender's IP:port)
//    {"t":"ack","id":101,"seq":42,"mode":"adaptive","lane":"N","st":"QUEUED",
//     "sig":"R","rem":11.4,"pri":0}
//      sig : G / Y / R for the vehicle's lane, "-" if it has no lane
//      rem : seconds left in that colour (R -> estimated time to green)
//      pri : 1 = emergency priority request recognised
// ============================================================================
