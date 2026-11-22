// Every constant of firmware v3, in one place, with the firmware's names.
// Source: docs/firmware-v3/intersection_esp32/v2i_common.h, intersection_esp32.ino and
// vehicle_node/vehicle_node.ino. Do not change a value here without changing the firmware too.

// ---------------- Network (v2i_common.h) -------------------------------------
const AP_SSID = 'V2I-Junction-01';
const AP_PASS = 'v2i12345';
const AP_CHANNEL = 6;
const INTERSECTION_IP_STR = '192.168.4.1';
const V2I_UDP_PORT = 4210; // vehicles -> intersection
const VEHICLE_ACK_PORT = 4211; // ACKs come back here on the vehicle
const V2I_MAX_PACKET = 200; // every packet must be shorter than this
const HTTP_PORT = 80;
const WS_PORT = 81;

// ---------------- Junction geometry (test-data origin) -----------------------
const CENTER_LAT = 31.500000;
const CENTER_LON = 74.300000;

const NUM_LANES = 4; // one lane per arm: N, E, S, W
const LANE_NAME = ['N', 'E', 'S', 'W'];
const ARM_BEARING = [0.0, 90.0, 180.0, 270.0]; // centre -> out along each arm

// ---------------- Vehicle types ----------------------------------------------
const VT_NORMAL = 0;
const VT_EMERGENCY = 1;

// ---------------- Lane-decision thresholds -----------------------------------
const DETECT_RADIUS_M = 150.0;
const JUNCTION_R_M = 10.0;
const QUEUE_ZONE_M = 60.0;
const QUEUE_SPEED_KMH = 5.0;
const ARM_HALF_ANGLE_DEG = 45.0;
const HEADING_TOL_DEG = 60.0;
const M_PER_DEG_LAT = 111320.0;

// ---------------- Signal timing (intersection_esp32.ino) ---------------------
const YELLOW_MS = 3000;
const ALL_RED_MS = 1000;
const FIXED_GREEN_MS = 30000; // FIXED: 30 s per lane
const G_MIN_MS = 5000; // ADAPTIVE min green, and min green before an early end
const G_MAX_MS = 30000; // ADAPTIVE max green
const IDLE_GREEN_MS = 5000; // ADAPTIVE: vehicles connected but no demand anywhere

// ---------------- AUTO mode ----------------------------------------------------
const VEHICLE_TIMEOUT_MS = 3000; // vehicle removed ([LOST]) after this silence
const AUTO_FIXED_AFTER_MS = 5000; // AUTO: no packet from anyone this long -> FIXED
const EARLY_END_FIXED_GREEN = true; // FIXED->ADAPTIVE: end a fixed green with no demand
const AUTO_SETTLE_MS = 1500; // ...but only after every vehicle had time to report

// ---------------- Webster parameters -------------------------------------------
const SAT_FLOW_VPH = 1800.0; // s, saturation flow per lane (veh/h)
const OBS_WINDOW_S = 20.0; // Qw treated as arriving within this window (toy-scale constant)
const Y_MAX = 0.90; // cap on Y = sum(y_i)
const C_MIN_S = 30.0;
const C_MAX_S = 90.0;
const K_APPROACH = 0.5; // PLACEHOLDER (to be tuned): weight of approaching vehicles in Qw

// ---------------- Density thresholds -------------------------------------------
const ALL_HIGH_QUEUED = 8;
const ALL_HIGH_APPROACH = 12;
const ALL_MED_QUEUED = 3;
const ALL_MED_APPROACH = 5;
// Per lane: PLACEHOLDERS for the toy scale
const LANE_HIGH_QUEUED = 3;
const LANE_HIGH_APPROACH = 5;
const LANE_MED_QUEUED = 2;
const LANE_MED_APPROACH = 3;

// ---------------- Emergency priority -------------------------------------------
const PREEMPT_MIN_GREEN_MS = 0; // 0 = end the current green at once
const PRIO_MIN_GREEN_MS = 5000; // a priority green lasts at least this long
const EMERG_HOLD_MAX_MS = 25000; // ...and at most this long
const RESUME_PREEMPTED_LANE = true; // lane cut short by priority is served next

// ---------------- Misc (intersection) ------------------------------------------
const MAX_VEH = 16;
const APP_DATA_VERSION = 2; // the app rejects frames without "v":2
const LOG_RX_DEFAULT = true;
const MISMATCH_LOG_MS = 2000; // at most one [MISMATCH] per vehicle per 2 s
const DENSITY_PERIOD_MS = 100;
const EXPIRE_PERIOD_MS = 250; // loop(): expireVehicles() every 250 ms
const STAT_PERIOD_MS = 1000;
const WS_PERIOD_MS = 500;
const DISPLAY_SLOT_MS = 50;

// ---------------- Vehicle unit (vehicle_node.ino) ------------------------------
const BEACON_MS = 500;
const SIM_STEP_MS = 100;
const STOP_LINE_M = 12.0; // must stay outside JUNCTION_R_M (+ noise)
const QUEUE_SPACING_M = 6.0;
const ACCEL_MS2 = 2.0;
const DECEL_MS2 = 3.0;
const MAX_DECEL_MS2 = 6.0;
const DEPART_END_M = 80.0;
const PARK_DIST_M = 400.0;
const RESTART_DELAY_MS = 15000;
const ACK_TIMEOUT_MS = 3000; // no ACK for this long => treat signal as RED
const REPLAY_INTERVAL_MS = 500;
const LOOP_TRIP = true;
const GPS_NOISE_M = 1.0;
const HDG_NOISE_DEG = 2.0;
const SPD_NOISE_KMH = 0.4;

// static_assert(STOP_LINE_M >= JUNCTION_R_M + 2.0f * GPS_NOISE_M) in the firmware:
const bool stopLineClearOfBox = STOP_LINE_M >= JUNCTION_R_M + 2.0 * GPS_NOISE_M;

// ---------------- Digital twin (not in the firmware) ---------------------------
/// The digital vehicle ids: 1001..65535. 101..202 stay reserved for the hardware presets.
const DIGITAL_VEHICLE_ID_MIN = 1001;
const DIGITAL_VEHICLE_ID_MAX = 65535;
const DIGITAL_CONTROLLER_NAME = 'Digital Intersection (Flutter)';
