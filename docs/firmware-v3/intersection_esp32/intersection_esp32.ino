// ============================================================================
//  V2I Smart Traffic - INTERSECTION UNIT  (ESP32 DevKit V1)
//
//  - Wi-Fi access point "V2I-Junction-01" (192.168.4.1, channel 6). Vehicles
//    (ESP32-S3 / ESP32 / ESP8266) send UDP "pos" packets to port 4210 every
//    500 ms; every packet gets a UDP ACK back to the sender's IP and port.
//  - LANE DECISION from the coordinates only (v2iClassify() in v2i_common.h).
//    The test-lane field "tl" is used ONLY to print [MISMATCH] warnings.
//  - DENSITY CHECK every 100 ms: queued / approaching / crossing / emergency
//    per lane, weighted queue Qw = queued + K_APPROACH * approaching,
//    LOW / MEDIUM / HIGH per lane and overall.
//  - SIGNALS: 4 lanes controlled INDIVIDUALLY (one green at a time).
//    green -> 3 s yellow -> 1 s all-red -> next lane.
//  - MODE (AUTO by default, no button needed):
//      no vehicle connected        -> FIXED   (30 s per lane, round-robin)
//      vehicle(s) sending data     -> ADAPTIVE (Webster, same formulas as SUMO)
//    Manual overrides: serial f / a / o, web /api/mode, WebSocket.
//  - EMERGENCY PRIORITY (ty = 1) in every mode.
//  - Serial Monitor 115200 baud. Commands:
//      f = force fixed   a = force adaptive   o = back to auto
//      v = vehicle table r = [RX] log on/off  p = print Webster plan now
//      h = help
//  - Web:  GET /  dashboard | GET /api/state | GET /api/mode?m=auto|fixed|adaptive
//          POST /api/vehicle (same JSON as the UDP packet)
//          WebSocket ws://192.168.4.1:81/ (state every 500 ms, accepts mode commands)
//
//  Libraries (Library Manager): ArduinoJson v7, TM1637 by Avishay Orpaz,
//  WebSockets by Markus Sattler. WiFi / WebServer come with the ESP32 core.
// ============================================================================
#include <WiFi.h>
#include <WiFiUdp.h>
#include <WebServer.h>
#include <WebSocketsServer.h>
#include <ArduinoJson.h>
#include <TM1637Display.h>
#include "v2i_common.h"

// ============================================================================
//  TUNABLE CONSTANTS
// ============================================================================
// ----------------------------- Pins (unchanged from your board) -------------
//                               N   E   S   W
const uint8_t PIN_R[NUM_LANES] = {13, 26, 32, 21};
const uint8_t PIN_Y[NUM_LANES] = { 4, 25, 23, 19};
const uint8_t PIN_G[NUM_LANES] = {27, 33, 22, 18};
constexpr uint8_t DISPLAY_CLK = 16;                                // shared CLK
constexpr uint8_t DISPLAY_DIO[NUM_LANES] = {17, 5, 14, 15};        // N, E, S, W

// ----------------------------- Displays (HW-069 / TM1637) -------------------
constexpr unsigned int DISPLAY_BIT_DELAY_US = 250;   // your working value; 100 = library default.
                                                     // One write takes about 0.2 ms * this value.
constexpr uint8_t  DISPLAY_BRIGHTNESS   = 5;         // 0..7
constexpr uint32_t DISPLAY_SLOT_MS      = 50;        // one display is serviced per slot (spreads bus time)
constexpr uint32_t DISPLAY_REFRESH_MS   = 5000;      // full rewrite of every display this often

// ----------------------------- Signal timing --------------------------------
constexpr uint32_t YELLOW_MS        = 3000;
constexpr uint32_t ALL_RED_MS       = 1000;
constexpr uint32_t FIXED_GREEN_MS   = 30000;   // FIXED: 30 s per lane
constexpr uint32_t G_MIN_MS         = 5000;    // ADAPTIVE min green, and min green before an early end
constexpr uint32_t G_MAX_MS         = 30000;   // ADAPTIVE max green
constexpr uint32_t IDLE_GREEN_MS    = 5000;    // ADAPTIVE: vehicles connected but no demand anywhere

// ----------------------------- AUTO mode -------------------------------------
constexpr uint32_t VEHICLE_TIMEOUT_MS     = 3000;  // vehicle removed ([LOST]) after this silence
constexpr uint32_t AUTO_FIXED_AFTER_MS    = 5000;  // AUTO: no packet from anyone this long -> FIXED
constexpr bool     EARLY_END_FIXED_GREEN  = true;  // FIXED->ADAPTIVE: end a fixed green with no demand
constexpr uint32_t AUTO_SETTLE_MS         = 1500;  // ...but only after every vehicle had time to report

// ----------------------------- Webster parameters ---------------------------
constexpr float SAT_FLOW_VPH  = 1800.0f;  // s, saturation flow per lane (veh/h)
constexpr float OBS_WINDOW_S  = 20.0f;    // Qw treated as arriving within this window (toy-scale constant)
constexpr float Y_MAX         = 0.90f;    // cap on Y = sum(y_i)
constexpr float C_MIN_S       = 30.0f;    // cycle length limits
constexpr float C_MAX_S       = 90.0f;
constexpr float K_APPROACH    = 0.5f;     // PLACEHOLDER (to be tuned): weight of approaching vehicles in Qw

// ----------------------------- Density thresholds ---------------------------
// Overall (your current rule)
constexpr uint16_t ALL_HIGH_QUEUED     = 8;
constexpr uint16_t ALL_HIGH_APPROACH   = 12;
constexpr uint16_t ALL_MED_QUEUED      = 3;
constexpr uint16_t ALL_MED_APPROACH    = 5;
// Per lane  - PLACEHOLDERS for the toy scale, tune them
constexpr uint8_t  LANE_HIGH_QUEUED    = 3;
constexpr uint8_t  LANE_HIGH_APPROACH  = 5;
constexpr uint8_t  LANE_MED_QUEUED     = 2;
constexpr uint8_t  LANE_MED_APPROACH   = 3;

// ----------------------------- Emergency priority ---------------------------
constexpr uint32_t PREEMPT_MIN_GREEN_MS  = 0;      // 0 = end the current green at once
constexpr uint32_t PRIO_MIN_GREEN_MS     = 5000;   // a priority green lasts at least this long
constexpr uint32_t EMERG_HOLD_MAX_MS     = 25000;  // ...and at most this long
constexpr bool     RESUME_PREEMPTED_LANE = true;   // lane cut short by priority is served next

// ----------------------------- Misc ------------------------------------------
constexpr int      MAX_VEH            = 16;
constexpr int      APP_DATA_VERSION   = 2;         // Flutter app rejects frames without "v":2
constexpr bool     LOG_RX_DEFAULT     = true;      // [RX] line per packet (toggle with 'r')
constexpr uint32_t MISMATCH_LOG_MS    = 2000;      // at most one [MISMATCH] per vehicle per 2 s
constexpr uint32_t DENSITY_PERIOD_MS  = 100;
constexpr uint32_t STAT_PERIOD_MS     = 1000;
constexpr uint32_t WS_PERIOD_MS       = 500;
constexpr uint8_t  AP_MAX_CLIENTS     = 10;        // 6 vehicles + laptop + phone + spare

// ============================================================================
//  Types & state
// ============================================================================
enum ReqMode : uint8_t { REQ_AUTO, REQ_FIXED, REQ_ADAPTIVE };   // what was asked for
enum Mode    : uint8_t { MODE_FIXED, MODE_ADAPTIVE };           // what the signals do
enum Phase   : uint8_t { PH_GREEN, PH_YELLOW, PH_ALLRED };
enum Density : uint8_t { D_LOW, D_MEDIUM, D_HIGH };

struct Veh {
  bool     used = false;
  uint16_t id = 0;
  uint8_t  type = VT_NORMAL;
  int8_t   lane = -1, tl = -1;
  uint8_t  st = ST_IGNORED, reason = RS_OK;
  float    spd = 0, hdg = -1, dist = 0, bearing = 0;
  double   lat = 0, lon = 0;
  int      rssi = 0;
  bool     hasRssi = false;
  uint32_t lastSeen = 0, pkts = 0, lost = 0, lastSeq = 0;
  uint32_t lastMismatchLog = 0;
  bool     prioLogged = false;
  uint32_t prioSince = 0;        // when this emergency vehicle first requested priority
  char     hw[12] = "";
};

struct LaneStat { uint8_t queued, approach, crossing, emerg; float qw; Density dens; };

struct Plan {                    // Webster result
  float L, Y, C;
  float q[NUM_LANES], y[NUM_LANES];
  float g[NUM_LANES];            // green seconds per lane (0 = skipped)
  bool  anyDemand;
};

Veh      vehs[MAX_VEH];
LaneStat ls[NUM_LANES];
Plan     decisionPlan;           // plan used for the current green (printed at each decision)
Plan     previewPlan;            // recomputed every second, used for red-time estimates
uint16_t totQueued = 0, totApproach = 0;
Density  overallDens = D_LOW;

ReqMode  reqMode   = REQ_AUTO;
Mode     effMode   = MODE_FIXED;    // latched at each lane decision
Mode     lastTarget = MODE_FIXED;
uint32_t targetSince = 0;           // when targetMode() last changed
bool     everRx    = false;
uint32_t lastAnyRxMs = 0;

Phase    phase = PH_ALLRED;
int      curLane = -1;
int      rrLane = NUM_LANES - 1;    // last NORMAL green (rotation pointer) -> first green is N
int      resumeLane = -1;           // normal lane cut short by a priority request
bool     prioGreen = false;         // current green is an emergency-priority green
uint16_t prioVehId = 0;
uint32_t prioStartMs = 0;
bool     cooldown[NUM_LANES] = {false, false, false, false};  // had priority -> waits one normal turn
uint32_t phaseStart = 0, phaseDur = ALL_RED_MS;
uint32_t pktRx = 0, pktBad = 0;
bool     logRx = LOG_RX_DEFAULT;

WiFiUDP          udp;
WebServer        server(80);
WebSocketsServer appSocket(81);

TM1637Display laneDisplayN(DISPLAY_CLK, DISPLAY_DIO[0], DISPLAY_BIT_DELAY_US);
TM1637Display laneDisplayE(DISPLAY_CLK, DISPLAY_DIO[1], DISPLAY_BIT_DELAY_US);
TM1637Display laneDisplayS(DISPLAY_CLK, DISPLAY_DIO[2], DISPLAY_BIT_DELAY_US);
TM1637Display laneDisplayW(DISPLAY_CLK, DISPLAY_DIO[3], DISPLAY_BIT_DELAY_US);
TM1637Display* laneDisplays[NUM_LANES] = { &laneDisplayN, &laneDisplayE, &laneDisplayS, &laneDisplayW };

// ============================================================================
//  Small helpers
// ============================================================================
static float r1(float x) { return roundf(x * 10.0f) / 10.0f; }
static float r2(float x) { return roundf(x * 100.0f) / 100.0f; }

const char* modeName(Mode m)       { return m == MODE_FIXED ? "fixed" : "adaptive"; }
const char* reqModeName(ReqMode m) { return m == REQ_AUTO ? "auto" : (m == REQ_FIXED ? "fixed" : "adaptive"); }
const char* densName(Density d)    { return d == D_HIGH ? "HIGH" : (d == D_MEDIUM ? "MEDIUM" : "LOW"); }
const char* phaseName()            { return phase == PH_GREEN ? "GREEN" : (phase == PH_YELLOW ? "YELLOW" : "ALL_RED"); }

int connectedVehicles() { int n = 0; for (auto &v : vehs) if (v.used) n++; return n; }
bool heardRecently()    { return everRx && millis() - lastAnyRxMs < AUTO_FIXED_AFTER_MS; }

// Mode the controller WANTS now (applied at the next lane decision)
Mode targetMode() {
  if (reqMode == REQ_FIXED)    return MODE_FIXED;
  if (reqMode == REQ_ADAPTIVE) return MODE_ADAPTIVE;
  return heardRecently() ? MODE_ADAPTIVE : MODE_FIXED;
}

// Human-readable reason for the effective / target mode
void modeReason(char *out, size_t n) {
  Mode t = targetMode();
  const char *pend = (t != effMode) ? " | switching at next lane decision" : "";
  if (reqMode == REQ_FIXED)         snprintf(out, n, "manual: fixed forced%s", pend);
  else if (reqMode == REQ_ADAPTIVE) snprintf(out, n, "manual: adaptive forced%s", pend);
  else if (t == MODE_ADAPTIVE && connectedVehicles() > 0)
                                    snprintf(out, n, "auto: %d vehicle(s) sending data -> adaptive%s", connectedVehicles(), pend);
  else if (t == MODE_ADAPTIVE)      snprintf(out, n, "auto: last vehicle heard %.1fs ago -> adaptive until %us of silence%s",
                                             (millis() - lastAnyRxMs) / 1000.0f, (unsigned)(AUTO_FIXED_AFTER_MS / 1000), pend);
  else if (!everRx)                 snprintf(out, n, "auto: no vehicle connected -> fixed%s", pend);
  else                              snprintf(out, n, "auto: no vehicle heard for %us -> fixed%s",
                                             (unsigned)(AUTO_FIXED_AFTER_MS / 1000), pend);
}

char sigOf(int lane) {
  if (lane != curLane) return 'R';
  return phase == PH_GREEN ? 'G' : (phase == PH_YELLOW ? 'Y' : 'R');
}
float phaseRemS() {
  uint32_t el = millis() - phaseStart;
  return el >= phaseDur ? 0.0f : (phaseDur - el) / 1000.0f;
}

// ============================================================================
//  Vehicle table + density check
// ============================================================================
Veh* findVeh(uint16_t id) { for (auto &v : vehs) if (v.used && v.id == id) return &v; return nullptr; }
Veh* allocVeh()           { for (auto &v : vehs) if (!v.used) return &v; return nullptr; }

bool isActive(const Veh &v) { return v.used && v.lane >= 0 && v.st != ST_IGNORED; }

Density laneLevel(const LaneStat &s) {
  if (s.queued >= LANE_HIGH_QUEUED || s.approach >= LANE_HIGH_APPROACH) return D_HIGH;
  if (s.queued >= LANE_MED_QUEUED  || s.approach >= LANE_MED_APPROACH)  return D_MEDIUM;
  return D_LOW;
}

void densityCheck() {
  memset(ls, 0, sizeof(ls));
  for (auto &v : vehs) {
    if (!isActive(v)) continue;
    LaneStat &s = ls[v.lane];
    if (v.st == ST_QUEUED)      s.queued++;
    if (v.st == ST_APPROACHING) s.approach++;
    if (v.st == ST_CROSSING)    s.crossing++;
    if (v.type == VT_EMERGENCY) s.emerg++;
  }
  totQueued = totApproach = 0;
  for (int l = 0; l < NUM_LANES; l++) {
    ls[l].qw   = ls[l].queued + K_APPROACH * ls[l].approach;   // weighted queue
    ls[l].dens = laneLevel(ls[l]);
    totQueued += ls[l].queued; totApproach += ls[l].approach;
  }
  overallDens = (totQueued >= ALL_HIGH_QUEUED || totApproach >= ALL_HIGH_APPROACH) ? D_HIGH :
                (totQueued >= ALL_MED_QUEUED  || totApproach >= ALL_MED_APPROACH)  ? D_MEDIUM : D_LOW;
}

bool laneHasDemand(int l) { return l >= 0 && (ls[l].qw > 0.0f || ls[l].emerg > 0); }

void expireVehicles() {
  uint32_t now = millis();
  for (auto &v : vehs)
    if (v.used && now - v.lastSeen > VEHICLE_TIMEOUT_MS) {
      Serial.printf("[LOST] id=%u %s - no packet for %.1fs (pkts=%lu lost=%lu) -> removed, %d vehicle(s) left\n",
                    v.id, v.hw, (now - v.lastSeen) / 1000.0f, (unsigned long)v.pkts, (unsigned long)v.lost,
                    connectedVehicles() - 1);
      v.used = false;
    }
}

// ============================================================================
//  Emergency helpers
// ============================================================================
// Nearest emergency vehicle that should get priority (APPROACHING or QUEUED,
// not on the lane that is cooling down after its own priority green)
Veh* priorityCandidate() {
  Veh *best = nullptr;
  for (auto &v : vehs) {
    if (!isActive(v) || v.type != VT_EMERGENCY) continue;
    if (v.st != ST_APPROACHING && v.st != ST_QUEUED) continue;
    if (cooldown[v.lane]) continue;
    if (!best || v.dist < best->dist) best = &v;
  }
  return best;
}
bool emergencyOnLane(int lane) {          // any emergency vehicle still on (or crossing from) lane
  for (auto &v : vehs) if (isActive(v) && v.type == VT_EMERGENCY && v.lane == lane) return true;
  return false;
}
int emergencyLaneForState() {
  if (prioGreen && phase == PH_GREEN) return curLane;
  Veh *c = priorityCandidate();
  return c ? c->lane : -1;
}

// ============================================================================
//  Webster adaptive timing (same formulas as the SUMO model)
//     q_i = Qw_i * 3600 / OBS_WINDOW_S      y_i = q_i / s
//     Y   = sum(y_i), capped at Y_MAX       L   = 4 * (yellow + all-red)
//     C0  = (1.5 L + 5) / (1 - Y)  in [C_MIN, C_MAX]
//     g_i = (y_i / Y) * (C0 - L)   in [G_MIN, G_MAX];  no demand -> skipped
// ============================================================================
Plan computePlan() {
  Plan p;
  p.L = NUM_LANES * (YELLOW_MS + ALL_RED_MS) / 1000.0f;
  p.Y = 0; p.anyDemand = false;
  for (int l = 0; l < NUM_LANES; l++) {
    p.q[l] = ls[l].qw * 3600.0f / OBS_WINDOW_S;
    p.y[l] = p.q[l] / SAT_FLOW_VPH;
    p.Y   += p.y[l];
  }
  if (p.Y > Y_MAX) {                                   // keep (1 - Y) positive; ratios y_i / Y unchanged
    float f = Y_MAX / p.Y;
    for (int l = 0; l < NUM_LANES; l++) p.y[l] *= f;
    p.Y = Y_MAX;
  }
  p.C = constrain((1.5f * p.L + 5.0f) / (1.0f - p.Y), C_MIN_S, C_MAX_S);
  float Gtot = p.C - p.L;
  for (int l = 0; l < NUM_LANES; l++) {
    if (p.y[l] <= 0.0f || p.Y <= 0.0f) { p.g[l] = 0.0f; continue; }
    p.anyDemand = true;
    p.g[l] = constrain(p.y[l] / p.Y * Gtot, G_MIN_MS / 1000.0f, G_MAX_MS / 1000.0f);
  }
  return p;
}

void printPlan(const Plan &p, const char *tag) {
  Serial.printf("[PLAN] %s Qw=[%.1f %.1f %.1f %.1f] q=[%.0f %.0f %.0f %.0f]veh/h y=[%.3f %.3f %.3f %.3f] "
                "Y=%.3f L=%.0fs C0=%.1fs g=[%.1f %.1f %.1f %.1f]s\n",
                tag, ls[0].qw, ls[1].qw, ls[2].qw, ls[3].qw, p.q[0], p.q[1], p.q[2], p.q[3],
                p.y[0], p.y[1], p.y[2], p.y[3], p.Y, p.L, p.C, p.g[0], p.g[1], p.g[2], p.g[3]);
}

// Green a lane would get on its next normal turn (0 = skipped)
float plannedGreenS(int lane) {
  if (effMode == MODE_FIXED) return FIXED_GREEN_MS / 1000.0f;
  if (!previewPlan.anyDemand) return IDLE_GREEN_MS / 1000.0f;
  return previewPlan.g[lane];
}

// Remaining time of the current green, including a priority hold
float greenRemS() {
  if (phase != PH_GREEN) return 0;
  float r = phaseRemS();
  if (prioGreen && emergencyOnLane(curLane)) {
    uint32_t held = millis() - prioStartMs;
    float hold = held >= EMERG_HOLD_MAX_MS ? 0.0f : (EMERG_HOLD_MAX_MS - held) / 1000.0f;
    if (hold > r) r = hold;                      // worst case: until the max hold
  }
  return r;
}

// Estimated seconds until `lane` turns green (ACK, dashboard, displays)
float etaGreenS(int lane) {
  const float clr = (YELLOW_MS + ALL_RED_MS) / 1000.0f;
  if (curLane < 0) return phaseRemS();
  if (lane == curLane && phase == PH_GREEN) return 0;
  float t;
  if (phase == PH_GREEN)       t = greenRemS() + clr;
  else if (phase == PH_YELLOW) t = phaseRemS() + ALL_RED_MS / 1000.0f;
  else                         t = phaseRemS();
  int from = rrLane;                                  // rotation continues after the last normal green
  for (int j = 1; j <= NUM_LANES; j++) {
    int l = (from + j) % NUM_LANES;
    if (l == lane) return t;
    float g = plannedGreenS(l);
    if (g > 0) t += g + clr;
  }
  return t;
}
float laneRemS(int lane) {
  char s = sigOf(lane);
  if (s == 'G') return greenRemS();
  if (s == 'Y') return phaseRemS();
  return etaGreenS(lane);
}

// ============================================================================
//  Signal state machine (one lane green at a time, each lane individually)
// ============================================================================
void applyOutputs() {
  for (int l = 0; l < NUM_LANES; l++) {
    bool g = (l == curLane && phase == PH_GREEN);
    bool y = (l == curLane && phase == PH_YELLOW);
    digitalWrite(PIN_G[l], g);
    digitalWrite(PIN_Y[l], y);
    digitalWrite(PIN_R[l], !(g || y));
  }
}
void startGreen(int lane, uint32_t dur, const char *why) {
  curLane = lane;
  phase = PH_GREEN; phaseStart = millis(); phaseDur = dur;
  applyOutputs();
  Serial.printf("[SIG ] lane %s GREEN %.1fs (%s)\n", LANE_NAME[lane], dur / 1000.0f, why);
}
void startYellow(const char *why, bool normalEnd = true) {
  if (normalEnd && !prioGreen) {            // a normal green ran to its end
    for (int l = 0; l < NUM_LANES; l++) if (cooldown[l]) {
      Serial.printf("[PRIO] lane %s has waited one normal turn -> may get priority again\n", LANE_NAME[l]);
      cooldown[l] = false;
    }
  }
  if (prioGreen) {
    cooldown[curLane] = true;               // this lane waits one normal turn
    prioGreen = false;
    Serial.printf("[PRIO] lane %s waits one normal turn before it can get priority again\n", LANE_NAME[curLane]);
  }
  phase = PH_YELLOW; phaseStart = millis(); phaseDur = YELLOW_MS;
  applyOutputs();
  Serial.printf("[SIG ] lane %s YELLOW %.1fs (%s)\n", LANE_NAME[curLane], YELLOW_MS / 1000.0f, why);
}
void startAllRed() {
  phase = PH_ALLRED; phaseStart = millis(); phaseDur = ALL_RED_MS;
  applyOutputs();
  Serial.printf("[SIG ] ALL RED %.1fs\n", ALL_RED_MS / 1000.0f);
}

void startPriorityGreen(Veh &e) {
  char why[96];
  snprintf(why, sizeof(why), "EMERGENCY PRIORITY id=%u d=%.0fm, hold until crossed, max %us",
           e.id, e.dist, (unsigned)(EMERG_HOLD_MAX_MS / 1000));
  prioGreen = true; prioVehId = e.id; prioStartMs = millis();
  startGreen(e.lane, PRIO_MIN_GREEN_MS, why);
  Serial.printf("[PRIO] lane %s GREEN for emergency id=%u, %.1f s after its request\n",
                LANE_NAME[e.lane], e.id, (millis() - e.prioSince) / 1000.0f);
}

void chooseNextLane() {
  densityCheck();

  // 1) latch the mode at the lane decision
  Mode t = targetMode();
  if (t != effMode) {
    effMode = t;
    char why[96]; modeReason(why, sizeof(why));
    Serial.printf("[MODE] effective mode now %s (%s)\n", effMode == MODE_FIXED ? "FIXED" : "ADAPTIVE", why);
  }

  // 2) emergency priority, every mode
  Veh *e = priorityCandidate();
  if (e) { startPriorityGreen(*e); return; }

  // 3) lane cut short by a priority green is served first
  int forced = -1;
  if (RESUME_PREEMPTED_LANE && resumeLane >= 0) {
    if (effMode == MODE_FIXED || laneHasDemand(resumeLane)) forced = resumeLane;
    resumeLane = -1;
  }

  if (effMode == MODE_FIXED) {
    int l = forced >= 0 ? forced : (rrLane + 1) % NUM_LANES;
    rrLane = l;
    char why[96];
    if (reqMode == REQ_FIXED) snprintf(why, sizeof(why), "fixed 30s round-robin: manual");
    else                      snprintf(why, sizeof(why), "fixed 30s round-robin: auto, no vehicle connected");
    if (forced >= 0) strlcat(why, ", resumes lane cut by priority", sizeof(why));
    startGreen(l, FIXED_GREEN_MS, why);
    return;
  }

  // ADAPTIVE (Webster), recomputed at every lane decision
  decisionPlan = computePlan();
  previewPlan  = decisionPlan;
  printPlan(decisionPlan, "adaptive");
  if (!decisionPlan.anyDemand) {
    int l = (rrLane + 1) % NUM_LANES;
    rrLane = l;
    startGreen(l, IDLE_GREEN_MS, "adaptive: vehicles connected but no demand -> idle green");
    return;
  }
  int pick = -1;
  if (forced >= 0 && decisionPlan.g[forced] > 0) pick = forced;
  for (int k = 1; pick < 0 && k <= NUM_LANES; k++) {
    int l = (rrLane + k) % NUM_LANES;
    if (decisionPlan.g[l] > 0.0f) pick = l;
  }
  rrLane = pick;
  char why[96];
  snprintf(why, sizeof(why), "adaptive Webster: Qw=%.1f y=%.3f %s density%s",
           ls[pick].qw, decisionPlan.y[pick], densName(ls[pick].dens),
           pick == forced ? ", resumes lane cut by priority" : "");
  startGreen(pick, (uint32_t)(decisionPlan.g[pick] * 1000.0f + 0.5f), why);
}

void signalTick() {
  uint32_t now = millis();
  uint32_t el = now - phaseStart;
  switch (phase) {
    case PH_GREEN: {
      // a) running priority green: hold until the emergency vehicle has crossed
      if (prioGreen) {
        uint32_t held = now - prioStartMs;
        if (held >= EMERG_HOLD_MAX_MS) {
          Serial.printf("[PRIO] max hold %us reached on lane %s -> ending priority green\n",
                        (unsigned)(EMERG_HOLD_MAX_MS / 1000), LANE_NAME[curLane]);
          startYellow("priority max hold reached");
        } else if (el >= phaseDur && !emergencyOnLane(curLane)) {
          Serial.printf("[PRIO] emergency id=%u has crossed -> ending priority green on %s after %.1fs\n",
                        prioVehId, LANE_NAME[curLane], held / 1000.0f);
          startYellow("emergency vehicle has crossed");
        }
        break;
      }
      // b) new emergency request
      Veh *e = priorityCandidate();
      if (e && e->lane == curLane) {                      // already green: turn it into a priority hold
        prioGreen = true; prioVehId = e->id; prioStartMs = now;
        Serial.printf("[PRIO] emergency id=%u on lane %s which is already green -> holding green until it crosses (max %us)\n",
                      e->id, LANE_NAME[curLane], (unsigned)(EMERG_HOLD_MAX_MS / 1000));
        break;
      }
      if (e && el >= PREEMPT_MIN_GREEN_MS) {
        Serial.printf("[PRIO] emergency id=%u on lane %s -> ending lane %s green now (yellow %us + all-red %us)\n",
                      e->id, LANE_NAME[e->lane], LANE_NAME[curLane],
                      (unsigned)(YELLOW_MS / 1000), (unsigned)(ALL_RED_MS / 1000));
        resumeLane = curLane;
        startYellow("preempted by emergency vehicle", false);
        break;
      }
      // c) AUTO fixed -> adaptive: end a fixed green that has no demand (after min green)
      if (EARLY_END_FIXED_GREEN && effMode == MODE_FIXED && targetMode() == MODE_ADAPTIVE &&
          now - targetSince >= AUTO_SETTLE_MS && el >= G_MIN_MS && !laneHasDemand(curLane)) {
        Serial.printf("[MODE] switching to adaptive: lane %s has no demand -> fixed green ended early after %.1fs\n",
                      LANE_NAME[curLane], el / 1000.0f);
        startYellow("fixed green ended early, no demand");
        break;
      }
      // d) normal end of green
      if (el >= phaseDur) startYellow("green time over");
      break;
    }
    case PH_YELLOW: if (el >= YELLOW_MS)  startAllRed();     break;   // never cut short
    case PH_ALLRED: if (el >= ALL_RED_MS) chooseNextLane();  break;   // never cut short
  }
}

// Detects automatic mode changes (logged once, applied at the next lane decision)
void modeWatch() {
  Mode t = targetMode();
  if (t == lastTarget) return;
  lastTarget = t; targetSince = millis();
  if (reqMode != REQ_AUTO) return;                        // manual changes are logged by setReqMode()
  if (t == MODE_ADAPTIVE)
    Serial.printf("[MODE] auto: vehicle data received (%d connected) -> ADAPTIVE from the next lane decision\n",
                  connectedVehicles());
  else
    Serial.printf("[MODE] auto: no vehicle heard for %us -> FIXED from the next lane decision\n",
                  (unsigned)(AUTO_FIXED_AFTER_MS / 1000));
}

void setReqMode(ReqMode m, const char *src) {
  reqMode = m;
  lastTarget = targetMode(); targetSince = millis();
  Serial.printf("[MODE] requested=%s (from %s) -> target %s, effective %s now, change applies at the next lane decision\n",
                reqModeName(m), src, modeName(lastTarget), modeName(effMode));
}
bool setReqModeByName(const char *s, const char *src) {
  if (!strcmp(s, "auto") || !strcmp(s, "o"))          { setReqMode(REQ_AUTO, src);     return true; }
  if (!strcmp(s, "fixed") || !strcmp(s, "f"))         { setReqMode(REQ_FIXED, src);    return true; }
  if (!strcmp(s, "adaptive") || !strcmp(s, "a"))      { setReqMode(REQ_ADAPTIVE, src); return true; }
  return false;
}

// ============================================================================
//  Four MM:SS countdown displays (time left in each lane's CURRENT colour)
//  One display per DISPLAY_SLOT_MS, written only when its value changes,
//  plus a full rewrite every DISPLAY_REFRESH_MS.
// ============================================================================
void updateLaneDisplays() {
  static int      lastShown[NUM_LANES] = {-1, -1, -1, -1};
  static uint32_t lastForce[NUM_LANES] = {0, 0, 0, 0};
  static uint8_t  next = 0;
  uint8_t lane = next; next = (next + 1) % NUM_LANES;
  uint32_t now = millis();

  float remaining = laneRemS(lane);
  if (remaining < 0) remaining = 0;
  uint16_t total = (uint16_t)ceilf(remaining - 0.001f);    // 30 at the start, then 29 ... 00
  if (total > 5999) total = 5999;
  int value = (total / 60) * 100 + (total % 60);           // MM:SS

  bool force = (now - lastForce[lane] >= DISPLAY_REFRESH_MS);
  if (!force && value == lastShown[lane]) return;           // unchanged: don't touch the bus
  lastShown[lane] = value;
  lastForce[lane] = now;
  laneDisplays[lane]->showNumberDecEx(value, 0x40, true);   // 0x40 = centre colon
}

// ============================================================================
//  Packet handling (UDP from vehicles, or HTTP POST /api/vehicle)
//  Builds the ACK into ackOut. Returns false for a bad packet.
// ============================================================================
bool processPacket(const char *json, char *ackOut, size_t ackSize) {
  JsonDocument d;
  if (deserializeJson(d, json) || strcmp(d["t"] | "", "pos") != 0) {
    pktBad++;
    Serial.printf("[RX! ] bad packet: %.80s\n", json);
    return false;
  }
  uint32_t id32 = d["id"] | 0UL;
  if (id32 == 0 || id32 > 65535 || d["lat"].isNull() || d["lon"].isNull()) {
    pktBad++;
    Serial.printf("[RX! ] packet without id/lat/lon: %.80s\n", json);
    return false;
  }
  uint16_t id = (uint16_t)id32;
  pktRx++;

  Veh *v = findVeh(id);
  if (!v) {
    v = allocVeh();
    if (!v) { Serial.println("[RX! ] vehicle table full"); return false; }
    *v = Veh(); v->used = true; v->id = id;
  }
  bool first = (v->pkts == 0);

  int   prevLane = v->lane;
  float prevDist = first ? 1e9f : v->dist;
  v->type     = (d["ty"] | 0) ? VT_EMERGENCY : VT_NORMAL;
  v->spd      = d["spd"] | 0.0f;
  v->hdg      = d["hdg"].isNull() ? -1.0f : d["hdg"].as<float>();
  v->lat      = d["lat"].as<double>();
  v->lon      = d["lon"].as<double>();
  v->tl       = laneIndex(d["tl"] | "");
  v->hasRssi  = !d["rssi"].isNull();
  v->rssi     = d["rssi"] | 0;
  v->lastSeen = millis();
  strlcpy(v->hw, d["hw"] | "?", sizeof(v->hw));

  // lost packets from gaps in "seq"
  if (!d["seq"].isNull()) {
    uint32_t s = d["seq"].as<uint32_t>();
    if (!first) {
      if (s > v->lastSeq + 1) v->lost += s - v->lastSeq - 1;
      // s <= lastSeq: vehicle restarted or duplicate -> no loss counted
    }
    v->lastSeq = s;
  }
  v->pkts++;

  // ---- lane decision from the coordinates ONLY ----
  V2IDecision r = v2iClassify(v->lat, v->lon, v->spd, v->hdg, v->hdg >= 0.0f, prevLane, prevDist);
  v->lane = r.lane; v->st = r.st; v->reason = r.reason; v->dist = r.dist; v->bearing = r.bearing;

  bool newConn = (connectedVehicles() == 1 && first);
  everRx = true; lastAnyRxMs = millis();
  if (first)
    Serial.printf("[CONN] id=%u %s %s connected (%d vehicle(s))%s\n", id, v->hw,
                  v->type == VT_EMERGENCY ? "EMERGENCY" : "normal", connectedVehicles(),
                  newConn ? " - first vehicle" : "");

  if (logRx)
    Serial.printf("[RX  ] id=%u %s %s lat=%.6f lon=%.6f spd=%.1f hdg=%.0f -> lane=%s tl=%s %s d=%.1fm brg=%.0f%s%s\n",
                  id, v->type == VT_EMERGENCY ? "EMERG" : "normal", v->hw, v->lat, v->lon, v->spd, v->hdg,
                  v->lane >= 0 ? LANE_NAME[v->lane] : "-", v->tl >= 0 ? LANE_NAME[v->tl] : "?",
                  stateName(v->st), v->dist, v->bearing,
                  v->st == ST_IGNORED ? " " : "", v->st == ST_IGNORED ? reasonName(v->reason) : "");

  // verification against the test lane (never used for the decision)
  if (v->lane >= 0 && v->tl >= 0 && v->lane != v->tl && millis() - v->lastMismatchLog >= MISMATCH_LOG_MS) {
    v->lastMismatchLog = millis();
    Serial.printf("[MISMATCH] id=%u computed lane %s but test data says %s (brg=%.0f d=%.1fm hdg=%.0f)\n",
                  id, LANE_NAME[v->lane], LANE_NAME[v->tl], v->bearing, v->dist, v->hdg);
  }

  if (v->type == VT_EMERGENCY && isActive(*v) && !v->prioLogged) {
    v->prioLogged = true;
    v->prioSince  = millis();
    Serial.printf("[PRIO] emergency id=%u detected on lane %s d=%.0fm %s -> priority requested\n",
                  id, LANE_NAME[v->lane], v->dist, stateName(v->st));
  }
  if (!isActive(*v)) v->prioLogged = false;                 // re-arm for the next trip

  densityCheck();
  modeWatch();

  // ---- ACK ----
  int pri = (v->type == VT_EMERGENCY && isActive(*v)) ? 1 : 0;
  if (v->lane >= 0) {
    char s = sigOf(v->lane);
    snprintf(ackOut, ackSize,
             "{\"t\":\"ack\",\"id\":%u,\"seq\":%lu,\"mode\":\"%s\",\"lane\":\"%s\",\"st\":\"%s\",\"sig\":\"%c\",\"rem\":%.1f,\"pri\":%d}",
             id, (unsigned long)v->lastSeq, modeName(effMode), LANE_NAME[v->lane], stateName(v->st), s,
             laneRemS(v->lane), pri);
  } else {
    snprintf(ackOut, ackSize,
             "{\"t\":\"ack\",\"id\":%u,\"seq\":%lu,\"mode\":\"%s\",\"lane\":\"-\",\"st\":\"%s\",\"sig\":\"-\",\"rem\":0,\"pri\":%d}",
             id, (unsigned long)v->lastSeq, modeName(effMode), stateName(v->st), pri);
  }
  return true;
}

void handleUdp() {
  int len;
  int budget = 8;                                         // max packets per loop pass
  while (budget-- > 0 && (len = udp.parsePacket()) > 0) {
    char buf[256];
    int n = udp.read(buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = 0;
    IPAddress rip   = udp.remoteIP();
    uint16_t  rport = udp.remotePort();
    char ack[V2I_MAX_PACKET];
    if (processPacket(buf, ack, sizeof(ack))) {
      udp.beginPacket(rip, rport);
      udp.write((const uint8_t *)ack, strlen(ack));
      udp.endPacket();
    }
  }
}

// ============================================================================
//  State JSON (HTTP + WebSocket). Must start with "v":2.
// ============================================================================
void buildState(JsonDocument &d) {
  char why[112]; modeReason(why, sizeof(why));
  int eml = emergencyLaneForState();

  d["v"]              = APP_DATA_VERSION;                 // FIRST key (app checks it)
  d["t"]              = "state";
  d["mode"]           = modeName(effMode);                // effective
  d["requested_mode"] = reqModeName(reqMode);             // auto / fixed / adaptive
  d["target_mode"]    = modeName(targetMode());
  d["mode_reason"]    = why;
  d["fallback"]       = (reqMode == REQ_AUTO && effMode == MODE_FIXED);
  d["emergency_lane"] = eml >= 0 ? LANE_NAME[eml] : "-";
  d["priority_active"]= prioGreen;
  d["uptime_s"]       = millis() / 1000;
  d["cur"]            = curLane >= 0 ? LANE_NAME[curLane] : "-";
  d["phase"]          = phaseName();
  d["rx"]             = pktRx;
  d["bad"]            = pktBad;
  d["controller"]     = "ESP32 Intersection Controller";
  d["intersection"]   = "STMS-RSU";
  d["online"]         = true;
  d["vehicle_count"]  = connectedVehicles();
  d["congestion"]     = densName(overallDens);
  d["queued_total"]   = totQueued;
  d["approaching_total"] = totApproach;

  JsonObject pl = d["plan"].to<JsonObject>();
  pl["C"] = r1(previewPlan.C); pl["Y"] = r2(previewPlan.Y); pl["L"] = r1(previewPlan.L);
  pl["K"] = K_APPROACH; pl["s"] = SAT_FLOW_VPH; pl["window_s"] = OBS_WINDOW_S;

  JsonArray lanes = d["lanes"].to<JsonArray>();
  for (int l = 0; l < NUM_LANES; l++) {
    JsonObject o = lanes.add<JsonObject>();
    char s[2] = { sigOf(l), 0 };
    o["lane"]        = LANE_NAME[l];
    o["sig"]         = s;
    o["rem"]         = r1(laneRemS(l));
    o["queued"]      = ls[l].queued;
    o["approach"]    = ls[l].approach;      // old key, kept for the app
    o["approaching"] = ls[l].approach;
    o["crossing"]    = ls[l].crossing;
    o["emerg"]       = ls[l].emerg;
    o["qw"]          = r1(ls[l].qw);
    o["density"]     = densName(ls[l].dens);
    o["y"]           = r2(previewPlan.y[l]);
    o["g"]           = r1((l == curLane && phase == PH_GREEN) ? phaseDur / 1000.0f : plannedGreenS(l));
  }

  JsonArray vs = d["vehicles"].to<JsonArray>();
  uint32_t now = millis();
  for (auto &v : vehs) {
    if (!v.used) continue;
    JsonObject o = vs.add<JsonObject>();
    o["id"]   = v.id;
    o["ty"]   = v.type;
    o["hw"]   = v.hw;
    o["lane"] = v.lane >= 0 ? LANE_NAME[v.lane] : "-";
    o["tl"]   = v.tl >= 0 ? LANE_NAME[v.tl] : "-";
    o["st"]   = stateName(v.st);
    o["spd"]  = r1(v.spd);
    o["hdg"]  = (int)v.hdg;
    o["dist"] = r1(v.dist);
    o["lat"]  = v.lat;
    o["lon"]  = v.lon;
    if (v.hasRssi) o["rssi"] = v.rssi; else o["rssi"] = nullptr;
    o["pkts"] = v.pkts;
    o["lost"] = v.lost;
    o["age_s"]= r1((now - v.lastSeen) / 1000.0f);
  }

  JsonObject timing = d["timing"].to<JsonObject>();
  float target = (phase == PH_GREEN) ? phaseDur / 1000.0f : (curLane >= 0 ? plannedGreenS(curLane) : 0.0f);
  timing["phase"]        = phaseName();
  timing["lane"]         = curLane >= 0 ? LANE_NAME[curLane] : "-";
  timing["target_green"] = r1(target);
  timing["elapsed"]      = r1((now - phaseStart) / 1000.0f);
  timing["remaining"]    = r1(phase == PH_GREEN ? greenRemS() : phaseRemS());
  timing["next_phase"]   = phase == PH_GREEN ? "YELLOW" : (phase == PH_YELLOW ? "ALL_RED" : "NEXT_GREEN");
  timing["priority"]     = prioGreen;
}

void broadcastAppState() {
  if (appSocket.connectedClients() == 0) return;
  JsonDocument d;
  buildState(d);
  String payload;
  serializeJson(d, payload);
  appSocket.broadcastTXT(payload);
}

void webSocketEvent(uint8_t clientNum, WStype_t type, uint8_t *payload, size_t length) {
  if (type == WStype_CONNECTED)    { Serial.printf("[APP ] WebSocket client %u connected\n", clientNum); return; }
  if (type == WStype_DISCONNECTED) { Serial.printf("[APP ] WebSocket client %u disconnected\n", clientNum); return; }
  if (type != WStype_TEXT) return;

  char msg[96];
  size_t n = length < sizeof(msg) - 1 ? length : sizeof(msg) - 1;
  memcpy(msg, payload, n); msg[n] = 0;
  while (n && (msg[n - 1] == ' ' || msg[n - 1] == '\n' || msg[n - 1] == '\r')) msg[--n] = 0;

  if (setReqModeByName(msg, "WebSocket")) return;          // "auto" / "fixed" / "adaptive"
  JsonDocument cmd;                                        // or {"mode":"auto"}
  if (!deserializeJson(cmd, msg)) {
    const char *m = cmd["mode"] | "";
    if (!setReqModeByName(m, "WebSocket")) Serial.printf("[APP ] unknown WebSocket command: %s\n", msg);
  }
}

void sendCors() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

const char PAGE[] PROGMEM = R"HTML(<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>V2I Junction</title>
<style>
body{font-family:system-ui,sans-serif;margin:12px;background:#0b1220;color:#e6edf7}
h1{font-size:18px;margin:0 0 8px}
.bar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:6px;font-size:13px}
button{padding:6px 12px;border-radius:6px;border:1px solid #3b4a66;background:#16233b;color:#e6edf7}
button.on{background:#c9a227;color:#111;border-color:#c9a227}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:8px}
.card{background:#111c30;border-radius:8px;padding:10px;font-size:14px}
.dot{width:24px;height:24px;border-radius:50%;display:inline-block;vertical-align:middle;margin-right:8px}
.G{background:#27ae60}.Y{background:#f1c40f}.R{background:#c0392b}
.HIGH{color:#ff7b6b}.MEDIUM{color:#f1c40f}.LOW{color:#7fd18b}
table{width:100%;border-collapse:collapse;margin-top:10px;font-size:13px}
td,th{padding:3px 6px;border-bottom:1px solid #22304a;text-align:left}
small{color:#8fa0bd}
</style></head><body>
<h1>V2I Junction &ndash; live</h1>
<div class=bar><b id=mode></b><span id=why></span></div>
<div class=bar>Requested:
<button id=b_auto onclick="setMode('auto')">Auto</button>
<button id=b_fixed onclick="setMode('fixed')">Fixed</button>
<button id=b_adaptive onclick="setMode('adaptive')">Adaptive</button>
<span id=info></span></div>
<div class=grid id=lanes></div>
<table><thead><tr><th>ID<th>Type<th>HW<th>Lane<th>Test<th>State<th>km/h<th>Dist m<th>RSSI<th>Pkts<th>Lost<th>Age s</tr></thead><tbody id=veh></tbody></table>
<script>
function setMode(m){fetch('/api/mode?m='+m).then(poll)}
function poll(){fetch('/api/state').then(r=>r.json()).then(s=>{
 mode.textContent='Effective: '+s.mode.toUpperCase();why.textContent=' - '+s.mode_reason;
 ['auto','fixed','adaptive'].forEach(m=>document.getElementById('b_'+m).className=s.requested_mode==m?'on':'');
 info.textContent='now '+s.cur+' '+s.phase+' '+s.timing.remaining+'s | vehicles '+s.vehicle_count+
  ' | congestion '+s.congestion+' | emergency '+s.emergency_lane+' | C0='+s.plan.C+'s Y='+s.plan.Y;
 lanes.innerHTML=s.lanes.map(l=>'<div class=card><span class="dot '+l.sig+'"></span><b>'+l.lane+'</b> '+
  (l.sig=='R'?'green in ~':'ends in ')+l.rem.toFixed(1)+'s<br><small>queued '+l.queued+' | approaching '+l.approaching+
  ' | emerg '+l.emerg+'<br>Qw '+l.qw.toFixed(1)+' | <span class='+l.density+'>'+l.density+'</span> | g '+l.g.toFixed(1)+'s</small></div>').join('');
 veh.innerHTML=s.vehicles.map(v=>'<tr><td>'+v.id+'<td>'+(v.ty?'EMERG':'normal')+'<td>'+v.hw+'<td>'+v.lane+'<td>'+v.tl+'<td>'+v.st+
  '<td>'+v.spd+'<td>'+v.dist+'<td>'+(v.rssi===null?'-':v.rssi)+'<td>'+v.pkts+'<td>'+v.lost+'<td>'+v.age_s+'</tr>').join('');
}).catch(()=>{})}
setInterval(poll,1000);poll();
</script></body></html>)HTML";

void setupHttp() {
  server.on("/", HTTP_GET, []() { server.send_P(200, "text/html", PAGE); });

  server.on("/api/state", HTTP_GET, []() {
    JsonDocument d; buildState(d);
    String out; serializeJson(d, out);
    sendCors(); server.send(200, "application/json", out);
  });

  server.on("/api/mode", HTTP_GET, []() {
    String m = server.arg("m");
    bool ok = m.length() && setReqModeByName(m.c_str(), "web /api/mode");
    char out[128];
    snprintf(out, sizeof(out), "{\"ok\":%s,\"requested_mode\":\"%s\",\"mode\":\"%s\",\"target_mode\":\"%s\"}",
             ok ? "true" : "false", reqModeName(reqMode), modeName(effMode), modeName(targetMode()));
    sendCors(); server.send(ok ? 200 : 400, "application/json", String(out));
  });

  server.on("/api/vehicle", HTTP_OPTIONS, []() { sendCors(); server.send(204); });
  server.on("/api/vehicle", HTTP_POST, []() {
    char ack[V2I_MAX_PACKET];
    bool ok = processPacket(server.arg("plain").c_str(), ack, sizeof(ack));
    sendCors();
    server.send(ok ? 200 : 400, "application/json", String(ok ? ack : "{\"error\":\"bad packet\"}"));
  });

  server.onNotFound([]() { server.send(404, "text/plain", "not found"); });
  server.begin();
}

// ============================================================================
//  Serial console
// ============================================================================
void printVehicles() {
  uint32_t now = millis();
  Serial.println("---- vehicles -------------------------------------------------------------------------");
  Serial.println("  id  hw        type    lane test state        spd km/h  dist m  RSSI  pkts  lost  age s");
  int n = 0;
  for (auto &v : vehs) if (v.used) {
    n++;
    char rs[8];
    if (v.hasRssi) snprintf(rs, sizeof(rs), "%d", v.rssi); else strcpy(rs, "-");
    Serial.printf("%4u  %-8s  %-6s  %-4s %-4s %-12s %8.1f  %6.1f  %4s  %4lu  %4lu  %5.1f\n", v.id, v.hw,
                  v.type == VT_EMERGENCY ? "EMERG" : "normal",
                  v.lane >= 0 ? LANE_NAME[v.lane] : "-", v.tl >= 0 ? LANE_NAME[v.tl] : "-",
                  stateName(v.st), v.spd, v.dist, rs, (unsigned long)v.pkts, (unsigned long)v.lost,
                  (now - v.lastSeen) / 1000.0f);
  }
  if (!n) Serial.println("(none)");
  Serial.println("---------------------------------------------------------------------------------------");
}

void printStatus() {
  char why[112]; modeReason(why, sizeof(why));
  float rem = phase == PH_GREEN ? greenRemS() : phaseRemS();
  Serial.printf("[STAT] %s (%s) req=%s | N:%c E:%c S:%c W:%c | cur=%s %s %.1fs%s | veh=%d | "
                "Qw N=%.1f %s E=%.1f %s S=%.1f %s W=%.1f %s | overall=%s\n",
                effMode == MODE_FIXED ? "FIXED" : "ADAPTIVE", why, reqModeName(reqMode),
                sigOf(0), sigOf(1), sigOf(2), sigOf(3),
                curLane >= 0 ? LANE_NAME[curLane] : "-", phaseName(), rem, prioGreen ? " PRIORITY" : "",
                connectedVehicles(),
                ls[0].qw, densName(ls[0].dens), ls[1].qw, densName(ls[1].dens),
                ls[2].qw, densName(ls[2].dens), ls[3].qw, densName(ls[3].dens), densName(overallDens));
}

void printHelp() {
  Serial.println("cmds: f=force fixed  a=force adaptive  o=auto  v=vehicle table  r=[RX] log on/off  p=plan  h=help");
}

void handleSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    switch (c) {
      case 'f': setReqMode(REQ_FIXED, "serial 'f'");    break;
      case 'a': setReqMode(REQ_ADAPTIVE, "serial 'a'"); break;
      case 'o': setReqMode(REQ_AUTO, "serial 'o'");     break;
      case 'v': printVehicles();                         break;
      case 'r': logRx = !logRx; Serial.printf("[RX  ] per-packet log %s\n", logRx ? "ON" : "OFF"); break;
      case 'p': densityCheck(); { Plan p = computePlan(); printPlan(p, "preview"); } break;
      case 'h': printHelp();                             break;
      default: break;                                    // ignore newlines etc.
    }
  }
}

// ============================================================================
void setup() {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  Serial.setTxBufferSize(2048);                 // fewer stalls when many [RX] lines are printed
#endif
  Serial.begin(115200);
  delay(300);                                   // once, at boot

  for (int l = 0; l < NUM_LANES; l++) {
    pinMode(PIN_R[l], OUTPUT); pinMode(PIN_Y[l], OUTPUT); pinMode(PIN_G[l], OUTPUT);
  }
  applyOutputs();                               // all red

  for (int l = 0; l < NUM_LANES; l++) {         // display self-test: 88:88, then live values
    laneDisplays[l]->setBrightness(DISPLAY_BRIGHTNESS);
    laneDisplays[l]->showNumberDecEx(8888, 0x40, true);
  }

  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  bool apOk = WiFi.softAP(AP_SSID, AP_PASS, AP_CHANNEL, 0, AP_MAX_CLIENTS);
  WiFi.setSleep(false);
  udp.begin(V2I_UDP_PORT);
  setupHttp();
  appSocket.begin();
  appSocket.onEvent(webSocketEvent);

  Serial.println();
  Serial.println("=== V2I INTERSECTION UNIT (ESP32) ===");
  Serial.printf("AP %s: SSID %s  pass %s  channel %d  IP %s  UDP %d\n", apOk ? "OK" : "FAILED",
                AP_SSID, AP_PASS, AP_CHANNEL, WiFi.softAPIP().toString().c_str(), V2I_UDP_PORT);
  Serial.println("Web: http://192.168.4.1/   WebSocket: ws://192.168.4.1:81/");
  Serial.printf("Mode: requested=AUTO -> FIXED %us/lane while no vehicle is connected, ADAPTIVE (Webster) when vehicles send data\n",
                (unsigned)(FIXED_GREEN_MS / 1000));
  printHelp();

  densityCheck();
  previewPlan = decisionPlan = computePlan();
  startAllRed();
}

void loop() {
  static uint32_t tDens = 0, tExpire = 0, tStat = 0, tDisp = 0, tWs = 0;
  uint32_t now = millis();

  handleUdp();
  server.handleClient();
  appSocket.loop();
  handleSerial();

  if (now - tDens   >= DENSITY_PERIOD_MS) { tDens = now; densityCheck(); modeWatch(); }
  if (now - tExpire >= 250)               { tExpire = now; expireVehicles(); }
  if (now - tStat   >= STAT_PERIOD_MS)    { tStat = now; previewPlan = computePlan(); printStatus(); }
  if (now - tDisp   >= DISPLAY_SLOT_MS)   { tDisp = now; updateLaneDisplays(); }
  if (now - tWs     >= WS_PERIOD_MS)      { tWs = now; broadcastAppState(); }

  signalTick();
}
