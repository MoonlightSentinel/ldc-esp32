# Prebuilt LDC for ESP32

This repository builds [LDC](ldc-developers/ldc) binaries using Espressif's
[LLVM fork](espressif/llvm-project) and creates custom releases that bundle
[LWDR](hmmdyl/LWDR) and several scripts for an easy start with D on an ESP32.

Inspired by the instructions found in the [Wiki](https://wiki.dlang.org/D_on_esp32/esp8266(llvm-xtensa+ldc)_and_how_to_get_started).

## Limitations:

- Part of LDC's default druntime bundled alongside LWDR (but with lower priority)
  might not compile.
## Known issues:

- LDC binaries for *nix dynamically link to libxml2
