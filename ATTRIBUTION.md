# Protocol sources

Razer protocol facts were checked against OpenRazer commit `477f4d6d3ab7e9deb6310d5bd3742560c5cbe80d` (GPL-2.0-or-later), especially `driver/razercommon.h`, `driver/razerchromacommon.c`, `driver/razermouse_driver.c`, and `daemon/openrazer_daemon/hardware/mouse.py`.

This implementation is independently written Swift/C. OpenRazer is at https://github.com/openrazer/openrazer. MiniChroma is an unofficial local utility and is not affiliated with Razer.

Read-only AppleSMC ABI facts, float/fixed-point formats, and M4 CPU sensor identifiers were checked against the Stats primary source: https://github.com/exelban/stats/blob/master/SMC/smc.swift and https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift. The backend is independently implemented, exposes metadata/read actions only, and is experimental because Apple does not publish a stable SMC sensor API.
