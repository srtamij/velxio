# Phase 2.EC probe — can an arbitrary multi-peripheral sketch run today?

**Empirical test** (not estimation). Compiled a real sketch
`sketches/periph_test/periph_test.ino` (Serial + I2C/BMP280 + SPI + servo-PWM
via LEDC, all built-in libs) with `arduino-cli ... esp32:esp32:esp32p4
--export-binaries`, then ran it + the blink through both emulator paths with
`run_sketch_probe.sh` (REAL_SCHED and REAL_INIT, `-d in_asm,int`, 14 s).

## Results

| Sketch / mode | app_main | setup() | loop() | ends at | sketch peripheral events |
|---|---|---|---|---|---|
| **periph_test** REAL_SCHED | ✗ | ✗ | ✗ | store-fault @0x4FF01F30 → reboot | none (4 GPIO from early init) |
| **periph_test** REAL_INIT | ✗ | ✗ | ✗ | fault_fetch PC=0 → reboot | none (GPIO/LEDC/ADC from early init) |
| **blink** REAL_SCHED | ✓ | ✓ | ✓ | scheduler + NULL-queue assert (Heisenbug) | **GPIO2 toggles** (`pin 2 -> 1`) |

## Findings (honest)

1. **An arbitrary multi-peripheral sketch does NOT reach `setup()`/`loop()` today.**
   - REAL_SCHED **crashes** (store fault → reboot): its ~102 bypass patches
     (esp. the sketch-specific loopTask-affinity writes @0x4000305C/306E) are
     tuned to the *blink*'s compiled addresses; `periph_test` lays out
     differently, so the patches corrupt the wrong instructions.
   - REAL_INIT gets through more system init but still faults (PC=0) before app
     code (the real-boot grind — flash-clock assert etc. — isn't done).
   - So the sketch's Serial / `Wire` (I2C) / `SPI` / `ledcWrite` (servo) code
     **never executes**.

2. **Even the working blink: GPIO toggles, but `Serial.println` produces NO
   output.** Zero `usb_serial_jtag`/`uart` TX events despite the blink calling
   `Serial.println("HIGH"/"LOW")` each loop. Root cause already known: the P4
   default console is USB-Serial/JTAG, whose driver gates on
   `usb_serial_jtag_is_connected()` = firmware static `false` in our run → output
   dropped.

3. **The peripheral models themselves work when driven** — proven at register
   level in the demo phases (I2C sensor responders 2.AM–2.DE, SPI responders
   2.AU/2.CD, LEDC 2.AC, etc.). The `ledc ch0 duty …` / `adc` / `gpio` events in
   the probe are real device responses, just triggered by early IDF init, not by
   the sketches.

## Bottom line

- **GPIO `digitalWrite`** ✓ (blink, real scheduler).
- **`Serial.print`** ✗ surfaced — needs console routed to a hardware UART, or the
  USB-Serial/JTAG connection modelled so output isn't dropped.
- **I2C / SPI / Servo from a real sketch** ✗ — the sketch doesn't boot to
  `setup()`; only the per-firmware-patched blink does. The device models are
  ready; what's missing is a real arbitrary sketch booting far enough to drive
  them, i.e. the full real-init path (2.EC blocker #4+).

## Serial-output investigation (asked: "fix Serial first")

Traced where `Serial` actually goes on this P4 build and why nothing shows:

- **`Serial` = UART0 (HardwareSerial), NOT USB-CDC.** boards.txt: esp32p4
  `cdc_on_boot=0` → `ARDUINO_USB_CDC_ON_BOOT=0` → `Serial` is `HardwareSerial`
  on UART0. Good news: **UART0 is modelled** (`esp32p4_uart.c`, Phase 2.AW) and
  **wired to `serial_hd(0)`** (esp32p4.c:1312), which under `-nographic` is
  stdio → it *would* print to stdout, plus a `uart_tx` JSON event.
- **But the bytes never reach UART0's FIFO.** Captured blink stdout under
  REAL_SCHED = **0 bytes**; zero `uart_tx` events. The blink's last executed
  function before the Heisenbug assert is `vTaskPlaceOnEventList` (NULL queue) —
  i.e. **`Serial.println("HIGH")` is almost certainly what triggers the
  NULL-queue crash**: `HardwareSerial::write` → `uart_write_bytes` → blocks on the
  UART driver's TX semaphore/ringbuffer, which was never created because
  `uart_driver_install`'s queues come from init that the REAL_SCHED bypass skips
  (the same skipped-init root as the determinism Heisenbug). GPIO2 still toggles
  because `digitalWrite` is a direct register write that needs no driver/queue.

**Conclusion: "fixing Serial" is NOT a bounded standalone task — it is downstream
of the boot.** The UART driver needs its real queues/semaphores, which require
the real `do_system_init` (the REAL_INIT path). The IDF *system* console
(esp_log/panic) is separately gated (USB-Serial/JTAG `is_connected` = firmware
static). So Serial, like I2C/SPI/servo, unblocks when the real boot completes —
not before. Recommend folding it into the real-init grind (option A) rather than
chasing it standalone.

## Next (to make a multi-peripheral sketch actually run)

Either (A) finish the full-fidelity real-init boot (blocker #4 flash-clock →
… → `vTaskStartScheduler`) so ANY sketch boots, then the I2C/SPI/PWM events fire
on their own; or (B) re-tune the per-sketch bypass patches for each target
firmware (not scalable). (A) is the real path. Separately, fix Serial output
(UART console or USB-JTAG connect model) — needed regardless.
