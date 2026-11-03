# Verification scope

Hardware verification on 3 November 2026 used a wired Razer DeathAdder V2 Mini (`1532:008C`, firmware 1.2), an Apple M4 MacBook Air, macOS 15.8.2, and a USB 2 hub. These results apply to that configuration.

## Automated and build checks

- 16 automated tests passed with zero failures.
- Release `.app` build using the `MiniChromaApp` Xcode scheme succeeded.
- The ad hoc signature was verified before ZIP packaging and again after ZIP extraction.
- A second MiniChroma process was rejected while the first held the device lock.
- Independent code review found no important issues in the final telemetry changes.

Tests cover packet fixtures, malformed replies, busy rejection, serialization, smoothing, stale-session ownership, mode changes, diagnostics gating, persistence, temperature formats/value validation, sensor selection, and temperature colour thresholds.

## Hardware results

| Check | Result |
| --- | --- |
| Metadata | Validated 90-byte firmware reply, interface 0, firmware 1.2 |
| Firmware effects | Off/static/spectrum/reactive and three breathing variants acknowledged |
| Sustained streaming | 7,500 validated frames in 300 seconds at a 25 Hz target, zero errors, maximum exchange latency 23.056 ms |
| Live volume/battery/CPU/rainbow/pulse | Each delivered 50 acknowledged frames during a two-second 25 Hz test through the real app pipeline |
| System audio | Real ScreenCaptureKit capture, 199 RMS samples and 199 acknowledged RGB frames, responding to a local test sound |
| CPU source | Read-only M4 AppleSMC CPU keys returned valid four-byte float values; UI identified the hottest sampled core/key |
| Cleanup | Firmware off acknowledged, brightness read back 0/255; no streaming process remained |

The initial relative-timer implementation averaged below the target rate. It was replaced with monotonic absolute deadlines and missed-frame skipping before the final 7,500-frame run. Competing-process behavior was also hardened with a device lock.

## What remains observational

Command acknowledgement proves the device accepted the command, not that a particular visual animation looked correct. Pointer/button usability, physical unplug/replug, real Mac sleep/wake, and installed login launch require observation in the user's setup. Automated UI inspection of the menu-bar-only app was not completed.

Audio permissions can depend on installation/signing identity. AppleSMC is a private interface and is explicitly experimental; compatibility may change after macOS updates. No SMC write or fan-control operation is exposed.

No compatibility claim is made for another mouse, PID, connection mode, or CPU generation. See [CONTRIBUTING.md](CONTRIBUTING.md) for support requests and model-specific validation.
