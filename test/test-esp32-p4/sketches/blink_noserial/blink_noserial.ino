// Serial-free blink for ESP32-P4 — Phase 2.EH decisive validation.
// If THIS blinks continuously on the emulator but the Serial blink stalls at
// Serial.println, it proves tick(2.EE)/CLIC-masking(2.EF-EG)/scheduler/delay/GPIO
// are all correct and isolates the remaining blocker to the Serial driver's NULL
// handle (do_system_init / uart_driver, Phase 2.EC).

#define LED_PIN 2

void setup() {
  pinMode(LED_PIN, OUTPUT);
}

void loop() {
  digitalWrite(LED_PIN, HIGH);
  delay(500);
  digitalWrite(LED_PIN, LOW);
  delay(500);
}
