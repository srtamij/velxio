// ESP32-P4 multi-peripheral capability probe.
// Exercises Serial (UART/USB-JTAG), I2C (Wire -> BMP280), SPI, and a
// servo-style 50 Hz PWM via LEDC. Used to measure how far a real
// multi-peripheral Arduino sketch boots + which device events fire.

#include <Wire.h>
#include <SPI.h>

#define LED_PIN     2
#define SERVO_PIN   4
#define BMP280_ADDR 0x76

void setup() {
  Serial.begin(115200);
  Serial.println("P4 periph-test: setup() reached");

  // --- I2C: read the BMP280 chip-id register (0xD0, expect 0x58) ---
  Wire.begin();
  Wire.beginTransmission(BMP280_ADDR);
  Wire.write(0xD0);
  Wire.endTransmission();
  Wire.requestFrom(BMP280_ADDR, 1);
  if (Wire.available()) {
    uint8_t id = Wire.read();
    Serial.print("I2C BMP280 chip-id: 0x");
    Serial.println(id, HEX);
  } else {
    Serial.println("I2C BMP280: no response");
  }

  // --- SPI: one transaction (e.g. a flash JEDEC-ID style command) ---
  SPI.begin();
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  uint8_t r = SPI.transfer(0x9F);
  SPI.endTransaction();
  Serial.print("SPI resp: 0x");
  Serial.println(r, HEX);

  // --- Servo via LEDC: 50 Hz, 16-bit, center pulse (~1.5 ms) ---
  ledcAttach(SERVO_PIN, 50, 16);
  ledcWrite(SERVO_PIN, 4915);   // 1.5ms / 20ms * 65535 ~= center

  pinMode(LED_PIN, OUTPUT);
}

void loop() {
  digitalWrite(LED_PIN, HIGH);
  Serial.println("tick HIGH");
  ledcWrite(SERVO_PIN, 3277);   // ~1.0 ms (0 deg)
  delay(500);

  digitalWrite(LED_PIN, LOW);
  Serial.println("tick LOW");
  ledcWrite(SERVO_PIN, 6553);   // ~2.0 ms (180 deg)
  delay(500);
}
