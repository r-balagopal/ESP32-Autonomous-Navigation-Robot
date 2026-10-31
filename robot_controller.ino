#include <WiFi.h>
#include <stdarg.h>
#include <math.h>

// ---------- Pins ----------
#define IN1 18
#define IN2 19
#define IN3 21
#define IN4 22
#define ENA 25            // L298N ENA (remove jumper)
#define ENB 26            // L298N ENB (remove jumper)
#define TRIG_PIN 5
#define ECHO_PIN 23

// ---------- WiFi ----------
const char* AP_SSID = "ROBOT_NET";
const char* AP_PASS = "robot1234";   // minimum 8 characters
const int   TCP_PORT = 8266;

// ---------- Speed (0-255) ----------
const int DRIVE_SPEED = 150;   // lower = slower, sensor gets more time
const int TURN_SPEED  = 170;
const int PWM_FREQ    = 2000;
const int PWM_RES     = 8;

// ---------- Calibration (tune these, AFTER setting the speeds) ----------
const int   OBSTACLE_DISTANCE = 25;   // cm
const int   OBSTACLE_HITS = 3;        // bad readings in a row before stopping
const float MS_PER_CM = 45.0;         // motor run time to travel 1 cm
const int   TURN_90_MS = 600;         // motor run time for a 90 degree turn
const int   NDIR = 8;                 // 8 = diagonal moves, 4 = orthogonal only
const bool  STOP_ON_DISCONNECT = true;

// ---------- Types ----------
struct P { int8_t x, y; };
enum Run { RUN_OK, RUN_STOPPED, RUN_BLOCKED };

// ---------- Grid / state ----------
const int MAXG = 24;
int GW = 12, GH = 12;
float cellCm = 25;
bool blocked[MAXG][MAXG];
int rx = 0, ry = 0;          // robot cell
int hd = 90;                 // heading: 0=up(+y) 90=right(+x) 180=down 270=left
int destX = 0, destY = 0;
bool haveDest = false;
bool running = false;
P path[MAXG * MAXG];
int pathLen = 0, pathIdx = 0;

const int DX[8] = {1, -1, 0, 0, 1, 1, -1, -1};
const int DY[8] = {0, 0, 1, -1, 1, -1, 1, -1};

WiFiServer server(TCP_PORT);
WiFiClient client;
bool wasConnected = false;
String rxBuf;

// ---------- Ultrasonic (median of 3) ----------
long readOnce() {
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(3);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);
  long duration = pulseIn(ECHO_PIN, HIGH, 20000);   // ~3.4 m max, faster checks
  if (duration == 0) return 999;
  return duration * 0.0343 / 2;
}

long getDistance() {
  long a = readOnce(); delay(5);
  long b = readOnce(); delay(5);
  long c = readOnce();
  if (a > b) { long t = a; a = b; b = t; }
  if (b > c) { long t = b; b = c; c = t; }
  if (a > b) { long t = a; a = b; b = t; }
  return b;  // median
}

// ---------- PWM speed control ----------
void pwmSetup() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(ENA, PWM_FREQ, PWM_RES);
  ledcAttach(ENB, PWM_FREQ, PWM_RES);
#else
  ledcSetup(0, PWM_FREQ, PWM_RES); ledcAttachPin(ENA, 0);
  ledcSetup(1, PWM_FREQ, PWM_RES); ledcAttachPin(ENB, 1);
#endif
}

void setSpeed(int s) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(ENA, s);
  ledcWrite(ENB, s);
#else
  ledcWrite(0, s);
  ledcWrite(1, s);
#endif
}

// ---------- Motors ----------
void stopMotors() {
  setSpeed(0);
  digitalWrite(IN1, LOW); digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW); digitalWrite(IN4, LOW);
}
void moveForward() {
  digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);
  digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);
  setSpeed(DRIVE_SPEED);
}
void moveBackward() {
  digitalWrite(IN1, LOW); digitalWrite(IN2, HIGH);
  digitalWrite(IN3, LOW); digitalWrite(IN4, HIGH);
  setSpeed(DRIVE_SPEED);
}
void turnRight() {
  digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW); digitalWrite(IN4, HIGH);
  setSpeed(TURN_SPEED);
}
void turnLeft() {
  digitalWrite(IN1, LOW); digitalWrite(IN2, HIGH);
  digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);
  setSpeed(TURN_SPEED);
}

// ---------- Messaging ----------
void sendf(const char* fmt, ...) {
  char b[48];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  Serial.println(b);
  if (client && client.connected()) {
    client.print(b);
    client.print('\n');
  }
}

bool inRange(int x, int y) { return x >= 0 && y >= 0 && x < GW && y < GH; }

void clearMap() {
  for (int x = 0; x < MAXG; x++)
    for (int y = 0; y < MAXG; y++) blocked[x][y] = false;
}

// Mark a newly found obstacle and tell the app (only if it is new)
void markObstacle(int x, int y) {
  if (!inRange(x, y) || blocked[x][y]) return;
  blocked[x][y] = true;
  sendf("OBSTACLE,%d,%d", x, y);
}

// ---------- A* (same rules as the app) ----------
float hf(int x, int y) {
  int ax = abs(x - destX), ay = abs(y - destY);
  if (NDIR == 8) return (ax > ay ? ax : ay) + 0.4142 * (ax < ay ? ax : ay);
  return ax + ay;
}

bool planPath() {
  static float g[MAXG][MAXG];
  static P from[MAXG][MAXG];
  static bool open[MAXG][MAXG], closed[MAXG][MAXG];
  for (int x = 0; x < GW; x++)
    for (int y = 0; y < GH; y++) {
      g[x][y] = 1e9; open[x][y] = false; closed[x][y] = false;
    }
  g[rx][ry] = 0;
  open[rx][ry] = true;

  while (true) {
    int cx = -1, cy = -1;
    float best = 1e9;
    for (int x = 0; x < GW; x++)
      for (int y = 0; y < GH; y++)
        if (open[x][y]) {
          float f = g[x][y] + hf(x, y);
          if (f < best) { best = f; cx = x; cy = y; }
        }
    if (cx < 0) return false;                       // no route
    if (cx == destX && cy == destY) break;
    open[cx][cy] = false;
    closed[cx][cy] = true;
    for (int k = 0; k < NDIR; k++) {
      int nx = cx + DX[k], ny = cy + DY[k];
      if (!inRange(nx, ny) || blocked[nx][ny] || closed[nx][ny]) continue;
      bool diag = DX[k] != 0 && DY[k] != 0;
      if (diag && blocked[cx + DX[k]][cy] && blocked[cx][cy + DY[k]]) continue;
      float t = g[cx][cy] + (diag ? 1.4142 : 1.0);
      if (t < g[nx][ny]) {
        g[nx][ny] = t;
        from[nx][ny] = {(int8_t)cx, (int8_t)cy};
        open[nx][ny] = true;
      }
    }
  }

  P tmp[MAXG * MAXG];
  int n = 0, x = destX, y = destY;
  while (!(x == rx && y == ry)) {
    tmp[n++] = {(int8_t)x, (int8_t)y};
    P p = from[x][y];
    x = p.x; y = p.y;
  }
  pathLen = 0;
  path[pathLen++] = {(int8_t)rx, (int8_t)ry};
  for (int i = n - 1; i >= 0; i--) path[pathLen++] = tmp[i];
  pathIdx = 0;
  return true;
}

// ---------- Commands from the app ----------
void handle(String l) {
  l.trim();
  if (!l.length()) return;
  Serial.println("RX: " + l);
  int a = l.indexOf(',');
  String c = a < 0 ? l : l.substring(0, a);
  long v[3] = {0, 0, 0};
  int n = 0, s = a;
  while (s >= 0 && n < 3) {
    int e = l.indexOf(',', s + 1);
    v[n++] = l.substring(s + 1, e < 0 ? l.length() : e).toInt();
    s = e;
  }

  if (c == "CONFIG") {
    GW = constrain(v[0], 1, MAXG);
    GH = constrain(v[1], 1, MAXG);
    cellCm = v[2] > 0 ? v[2] : 25;
    clearMap();
  } else if (c == "STARTPOS") {
    if (inRange(v[0], v[1])) { rx = v[0]; ry = v[1]; hd = 90; }  // assumes facing right (+x)
  } else if (c == "DEST") {
    if (inRange(v[0], v[1])) { destX = v[0]; destY = v[1]; haveDest = true; }
  } else if (c == "OBS") {
    if (inRange(v[0], v[1])) blocked[v[0]][v[1]] = true;
  } else if (c == "RMOBS") {
    if (inRange(v[0], v[1])) blocked[v[0]][v[1]] = false;
  } else if (c == "CLEAROBS") {
    clearMap();
  } else if (c == "START") {
    if (running) return;
    if (!haveDest || !planPath()) { sendf("STATUS,ERROR"); return; }
    running = true;
    sendf("STATUS,NAVIGATING");
  } else if (c == "STOP") {
    running = false;
    stopMotors();
    sendf("STATUS,STOPPED");
  } else if (c == "RESET") {
    running = false;
    stopMotors();
    clearMap();
    haveDest = false;
    sendf("STATUS,STOPPED");
  }
}

void pollClient() {
  WiFiClient c = server.available();
  if (c) {
    if (client) client.stop();
    client = c;
    client.setNoDelay(true);
    rxBuf = "";
  }
  bool now = client && client.connected();
  if (wasConnected && !now && STOP_ON_DISCONNECT) {
    running = false;
    stopMotors();
  }
  wasConnected = now;
  while (now && client.available()) {
    char ch = client.read();
    if (ch == '\n' || ch == '\r') {
      if (rxBuf.length()) { handle(rxBuf); rxBuf = ""; }
    } else {
      rxBuf += ch;
    }
  }
}

// ---------- Timed motion with stop + obstacle checks ----------
Run runFor(unsigned long ms, bool checkObs, unsigned long &el) {
  unsigned long t0 = millis();
  int hits = 0;
  el = 0;
  while ((el = millis() - t0) < ms) {
    pollClient();
    if (!running) { stopMotors(); return RUN_STOPPED; }
    if (checkObs) {
      if (getDistance() <= OBSTACLE_DISTANCE) {
        if (++hits >= OBSTACLE_HITS) { stopMotors(); return RUN_BLOCKED; }
      } else {
        hits = 0;
      }
    }
    delay(10);
  }
  return RUN_OK;
}

int headingFor(int ddx, int ddy) {
  int a = (int)round(atan2((float)ddx, (float)ddy) * 180.0 / PI);
  return (a + 360) % 360;
}

bool turnTo(int target) {
  int d = ((target - hd + 540) % 360) - 180;   // positive = turn right
  if (d == 0) return true;
  unsigned long ms = (unsigned long)abs(d) * TURN_90_MS / 90;
  if (d > 0) turnRight(); else turnLeft();
  unsigned long el;
  Run r = runFor(ms, false, el);
  stopMotors();
  if (r == RUN_STOPPED) return false;
  hd = target;
  sendf("POS,%d,%d,%d", rx, ry, hd);
  delay(150);
  return true;
}

// ---------- Spin left and right, read the sensor, mark blocked neighbours ----------
// Returns false if the mission was stopped during the scan.
bool scanSurroundings() {
  const int offsets[4] = {-45, -90, 45, 90};   // relative to the blocked heading
  int base = hd;
  for (int i = 0; i < 4; i++) {
    int a = ((base + offsets[i]) % 360 + 360) % 360;
    if (!turnTo(a)) return false;
    long d = getDistance();
    bool diag = (a % 90) != 0;
    float limit = OBSTACLE_DISTANCE * (diag ? 1.4142 : 1.0);  // diagonal cell is further away
    if (d <= limit) {
      int nx = rx + (int)round(sin(a * PI / 180.0));
      int ny = ry + (int)round(cos(a * PI / 180.0));
      markObstacle(nx, ny);
    }
  }
  return true;
}

// ---------- One path step ----------
void missionStep() {
  if (rx == destX && ry == destY) {
    running = false;
    sendf("STATUS,ARRIVED");
    return;
  }
  P nxt = path[pathIdx + 1];
  int ddx = nxt.x - rx, ddy = nxt.y - ry;

  if (!turnTo(headingFor(ddx, ddy))) return;

  bool diag = ddx != 0 && ddy != 0;
  unsigned long ms = (unsigned long)(cellCm * MS_PER_CM * (diag ? 1.4142 : 1.0));
  unsigned long el;
  moveForward();
  Run r = runFor(ms, true, el);
  stopMotors();
  if (r == RUN_STOPPED) return;

  if (r == RUN_BLOCKED) {
    // 1. back up to the centre of the current cell
    unsigned long back;
    moveBackward();
    runFor(el, false, back);
    stopMotors();
    if (!running) return;

    // 2. mark the cell ahead, then spin left and right to scan the neighbours
    markObstacle(nxt.x, nxt.y);
    sendf("STATUS,REPLANNING");
    if (!scanSurroundings()) return;

    // 3. choose a new path using what the scan found
    if (!planPath()) {
      running = false;
      sendf("STATUS,ERROR");
      return;
    }
    sendf("STATUS,NAVIGATING");
    return;
  }

  rx = nxt.x; ry = nxt.y;
  pathIdx++;
  sendf("POS,%d,%d,%d", rx, ry, hd);
  delay(100);
}

// ---------- Arduino ----------
void setup() {
  Serial.begin(115200);
  pinMode(IN1, OUTPUT); pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT); pinMode(IN4, OUTPUT);
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  pwmSetup();
  stopMotors();
  clearMap();

  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  server.begin();
  Serial.print("WiFi: ");
  Serial.print(AP_SSID);
  Serial.print("  IP: ");
  Serial.println(WiFi.softAPIP());
}

void loop() {
  pollClient();
  if (running) missionStep();
  else delay(5);
}