#!/usr/bin/env bash
# Phase 2.EJ — which Serial implementation does the blink use, and does its TX
# path reach an emulated device?
set -u
ELF=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4/blink.ino.elf
echo "=== HWCDC / HardwareSerial / usb_serial_jtag symbols ==="
readelf -sW "$ELF" | grep -icE "hwcdc"
readelf -sW "$ELF" | grep -cE "HardwareSerial"
readelf -sW "$ELF" | grep -icE "usb_serial_jtag"
echo "--- sample HWCDC symbols ---"
readelf -sW "$ELF" | grep -iE "hwcdc" | awk '{print $2, $8}' | head -8
echo "--- sample usb_serial_jtag symbols ---"
readelf -sW "$ELF" | grep -iE "usb_serial_jtag" | awk '{print $2, $8}' | head -10
echo "--- Serial object symbol ---"
readelf -sW "$ELF" | awk '$8=="Serial" || $8=="Serial0" || $8=="USBSerial" || $8=="HWCDCSerial" {print $2, $4, $8}'
echo "--- key TX functions ---"
readelf -sW "$ELF" | grep -E "write_bytes|txfifo|tx_flush|WriteByte|uart_tx|_write" | awk '{print $2, $8}' | head -10
