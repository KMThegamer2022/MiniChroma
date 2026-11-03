# Contributing

## Report a bug

Use the bug issue template. Include the exact mouse model, connection type, USB VID/PID, firmware if known, macOS version, Mac chip, effect, expected behavior, actual behavior, and reproduction steps. State whether another RGB controller was running.

Start with **Diagnostics → Read device** or `swift run minichroma-diagnostic read`. Review the output before posting. Remove USB serial numbers, user names, home-directory paths, device UUIDs, audio content, and unrelated hardware details. Do not attach a complete `ioreg` or System Information dump. The built-in metadata read is intentionally limited to the supported device and firmware.

## Adding another mouse

There are two routes:

1. **Request investigation:** open a Device support request using the Issues tab. Supply the information below. A maintainer may be able to research it, but an issue is not a promise or compatibility claim.
2. **Implement and verify support:** contribute a model-specific profile and transport/command routing, byte-level tests, and hardware evidence from that exact mouse. A hardware owner is needed for verification.

### Information needed

- Exact Razer model and revision, as printed on the device or shown by the manufacturer.
- Wired, wireless receiver, or Bluetooth connection. For wireless devices, identify each mode separately; the mouse and receiver may expose different PIDs and protocols.
- USB vendor and product IDs, in hexadecimal. Include the receiver's IDs when applicable. Do not include a serial number.
- macOS version and build, and Mac chip (for example, Apple M4).
- Firmware version, if available through an established read command.
- Desired effects/features and any existing behavior that already works.
- Links to model-specific OpenRazer, OpenRGB, or comparable primary-source implementation/support discussions.
- Redacted diagnostic output and whether you can test changes on the physical device.

For Bluetooth devices, USB VID/PID may not be applicable; describe the connection and available model identifiers without posting unique addresses.

### Implementation guidance

The current USB match, interface, and protocol are intentionally fixed to `1532:008C`. Relevant files are:

- `Sources/USBBridge/USBBridge.c`: device discovery, interface index, timeout-bound control transfers, and process lock.
- `Sources/ChromaCore/Core.swift`: report framing, command factories, response validation, and colour generation.
- `Sources/ChromaCore/USBTransport.swift`: serialized device ownership and effect application.
- `Sources/MiniChroma/MiniChromaApp.swift`: effect availability, UI, lifecycle, and diagnostics.
- `Tests/ChromaCoreTests`: packet fixtures, effect behavior, lifecycle ownership, and persistence.

For another mouse, introduce explicit model/capability routing instead of broadening the existing match or replacing its PID. Verify the USB interface index, transaction ID, report format, command family, storage policy, LED zones, and response behavior from that model's primary-source implementation. Firmware and streamed effects must remain separate.

Do not assume a named effect or 25 Hz streaming is supported because a related mouse supports it. Start with established read commands, validate replies, then test reversible volatile lighting changes. Do not introduce firmware updates, persistent per-frame writes, driver detachment, sensor-polling changes, or fan controls as part of RGB support.

Add literal protocol fixtures and failure tests before implementing the new path. Run the full suite and build the `.app`. Hardware verification should cover individual effects, normal pointer/button behavior, reconnect, sleep/wake, and staged streaming rates. Record the exact model/firmware and measured frame count/duration/errors; finish lighting tests with off and zero brightness where the model supports it.

Only mark a device supported after its implementation and hardware evidence are reviewed. Until then, label the work experimental or unverified.

## Development checks

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./build.sh
```

Keep pure protocol/effect logic separate from macOS input providers and USB transport. Preserve serialized exchanges and cancellation ownership. Avoid unrelated refactors in a device-support change, and describe which checks were automated versus physically observed.

By submitting a contribution, you confirm you can contribute it under this repository's MIT license. Do not copy differently licensed implementation code; independently implement protocol facts and retain appropriate attribution.
