/*
  ESP32 + MPU6050 -- standalone wearable fall detector with BLE alert + WiFi OTA
  Wearable Fall Detection System capstone project

  Features:
    - BLE server that advertises continuously so a phone app can find and
      connect to this device by name ("FallDetector").
    - A single "Alert" characteristic that the ESP32 notifies the moment
      a fall is confirmed (2 consecutive fall-classified windows).
    - The ML pipeline runs regardless of whether a phone is connected --
      BLE is just how the result gets reported outward.
    - WiFi OTA (Over-The-Air) updates: after ONE final wired upload of this
      firmware, all future firmware updates can be pushed wirelessly from
      Arduino IDE over WiFi -- no USB cable needed again. This is the
      standard mechanism for wireless ESP32 reflashing (not Bluetooth --
      Arduino IDE doesn't support BLE-based flashing for ESP32).
    - Runs entirely from battery power once flashed; USB is only needed
      for this one final wired upload, or to recharge.
*/

#include <Wire.h>
#include <Wearable_Fall_Detection_inferencing.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <WiFi.h>
#include <ArduinoOTA.h>

// ---------- WiFi / OTA setup ----------
// Fill in your WiFi network -- the ESP32 and your laptop must be on the
// SAME network for Arduino IDE to find it as a wireless upload target.
const char *WIFI_SSID = "YOUR_WIFI_NAME";
const char *WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

void setupOTA() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  Serial.print("[WiFi] Connecting");
  unsigned long startAttempt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startAttempt < 10000) {
    delay(300);
    Serial.print(".");
  }

  if (WiFi.status() != WL_CONNECTED) {
    // Not fatal -- the device still works fully offline (BLE + inference
    // don't need WiFi at all). OTA just won't be available until it can
    // reach this network.
    Serial.println("\n[WiFi] Could not connect -- continuing without OTA");
    return;
  }

  Serial.print("\n[WiFi] Connected, IP address: ");
  Serial.println(WiFi.localIP());

  ArduinoOTA.setHostname("fall-detector-esp32");
  ArduinoOTA.onStart([]() { Serial.println("[OTA] Update starting..."); });
  ArduinoOTA.onEnd([]() { Serial.println("\n[OTA] Update complete"); });
  ArduinoOTA.onError([](ota_error_t error) {
    Serial.print("[OTA] Error: ");
    Serial.println(error);
  });
  ArduinoOTA.begin();
  Serial.println("[OTA] Ready -- select this device's network port in Arduino IDE to upload wirelessly");
}

// ---------- BLE setup ----------
// Generate your own UUIDs (e.g. at uuidgenerator.net) rather than reusing
// these exactly, so your device doesn't collide with anyone else's project.
#define SERVICE_UUID        "6b1a1e00-2f6a-4e40-9a6e-2b7d0f7a11a1"
#define ALERT_CHAR_UUID      "6b1a1e01-2f6a-4e40-9a6e-2b7d0f7a11a1"

BLEServer *bleServer = nullptr;
BLECharacteristic *alertCharacteristic = nullptr;
bool deviceConnected = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    deviceConnected = true;
    Serial.println("[BLE] Phone connected");
  }
  void onDisconnect(BLEServer *server) override {
    deviceConnected = false;
    Serial.println("[BLE] Phone disconnected -- resuming advertising");
    delay(200);
    server->startAdvertising();  // keep advertising so the app can reconnect
  }
};

void setupBLE() {
  BLEDevice::init("FallDetector");
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService *service = bleServer->createService(SERVICE_UUID);
  alertCharacteristic = service->createCharacteristic(
      ALERT_CHAR_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  alertCharacteristic->addDescriptor(new BLE2902());
  alertCharacteristic->setValue("no_fall");

  service->start();
  bleServer->getAdvertising()->start();
  Serial.println("[BLE] Advertising as 'FallDetector'");
}

// ---------- MPU6050 setup ----------
const int MPU_ADDR = 0x68;
const float ACCEL_SENSITIVITY = 2048.0;   // LSB per g,     +-16g range
const float GYRO_SENSITIVITY  = 16.4;     // LSB per deg/s, +-2000dps range

const unsigned long SAMPLE_INTERVAL_MS = 1000 / EI_CLASSIFIER_FREQUENCY;
unsigned long lastSampleTime = 0;

static float featureBuffer[EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE];
size_t featureIx = 0;

const int FALL_CONFIRM_COUNT = 2;
int consecutiveFallWindows = 0;
bool alertActive = false;

void writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);
  Wire.write(value);
  Wire.endTransmission();
}

void setup() {
  Serial.begin(115200);
  delay(500);  // shorter delay is fine now -- not waiting on a laptop connection

  Wire.begin(21, 22);  // adjust if your compact board uses different I2C pins
  writeRegister(0x6B, 0x00); // wake up
  writeRegister(0x1C, 0x18); // accel +-16g
  writeRegister(0x1B, 0x18); // gyro +-2000dps
  delay(100);

  setupBLE();
  setupOTA();

  Serial.println("Wearable Fall Detection -- standalone mode started");
}

void readSensorInto(float *out) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 14, true);

  int16_t ax_raw = Wire.read() << 8 | Wire.read();
  int16_t ay_raw = Wire.read() << 8 | Wire.read();
  int16_t az_raw = Wire.read() << 8 | Wire.read();
  Wire.read() << 8 | Wire.read();  // discard temperature
  int16_t gx_raw = Wire.read() << 8 | Wire.read();
  int16_t gy_raw = Wire.read() << 8 | Wire.read();
  int16_t gz_raw = Wire.read() << 8 | Wire.read();

  out[0] = ax_raw / ACCEL_SENSITIVITY;
  out[1] = ay_raw / ACCEL_SENSITIVITY;
  out[2] = az_raw / ACCEL_SENSITIVITY;
  out[3] = gx_raw / GYRO_SENSITIVITY;
  out[4] = gy_raw / GYRO_SENSITIVITY;
  out[5] = gz_raw / GYRO_SENSITIVITY;
}

int rawFeatureGetData(size_t offset, size_t length, float *out_ptr) {
  memcpy(out_ptr, featureBuffer + offset, length * sizeof(float));
  return 0;
}

void sendAlert(const char *status) {
  if (alertCharacteristic == nullptr) return;
  alertCharacteristic->setValue(status);
  if (deviceConnected) {
    alertCharacteristic->notify();
  }
  // If no phone is connected right now, the characteristic's value still
  // updates, so a phone that connects moments later can read the last
  // known status even if it missed the live notification.
}

void runInference() {
  ei::signal_t signal;
  signal.total_length = EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE;
  signal.get_data = &rawFeatureGetData;

  ei_impulse_result_t result = { 0 };
  EI_IMPULSE_ERROR err = run_classifier(&signal, &result, false);
  if (err != EI_IMPULSE_OK) {
    Serial.print("Classifier failed with error code: ");
    Serial.println(err);
    return;
  }

  float bestScore = 0;
  const char *bestLabel = "";
  for (size_t i = 0; i < EI_CLASSIFIER_LABEL_COUNT; i++) {
    if (result.classification[i].value > bestScore) {
      bestScore = result.classification[i].value;
      bestLabel = result.classification[i].label;
    }
  }

  Serial.print("Prediction: ");
  Serial.print(bestLabel);
  Serial.print(" (");
  Serial.print(bestScore * 100, 1);
  Serial.println("%)");

  if (strcmp(bestLabel, "fall") == 0 && bestScore > 0.6) {
    consecutiveFallWindows++;
    if (consecutiveFallWindows >= FALL_CONFIRM_COUNT && !alertActive) {
      alertActive = true;
      Serial.println("*** FALL ALERT TRIGGERED -- notifying phone ***");
      sendAlert("fall_detected");
    }
  } else {
    consecutiveFallWindows = 0;
    if (alertActive) {
      alertActive = false;
      Serial.println("-- alert cleared --");
      sendAlert("no_fall");
    }
  }
}

void loop() {
  ArduinoOTA.handle();  // must be called regularly so OTA uploads can be received

  unsigned long now = millis();
  if (now - lastSampleTime < SAMPLE_INTERVAL_MS) {
    return;
  }
  lastSampleTime = now;

  float sample[6];
  readSensorInto(sample);

  for (int i = 0; i < 6; i++) {
    featureBuffer[featureIx++] = sample[i];
  }

  if (featureIx >= EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE) {
    runInference();
    featureIx = 0;
  }
}
