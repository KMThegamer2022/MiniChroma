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

## Version 0.1.1 follow-up — 11 November 2026

23 automated tests passed, including regressions that first reproduced delayed audio-stop/start and immediate wake races, stale input leaving the last light on, missing capture recovery, and residual light below the noise gate. Audio now uses a gate-normalized green/yellow/red digital RMS map, exact black for silence/stale input, identity-guarded ScreenCaptureKit callbacks, ordered cleanup, and bounded restart attempts. User-declined permission and deliberate capture stops wait for explicit Apply.

Actual colour-editor UI checks verified visible RGB sliders/swatch and Blue → `#0000FF`, Red → `#FF0000`. The editor is now a dedicated activated window rather than a picker inside a transient menu popup.

The installed app passed real capture-recovery checks: fresh samples and 60 frames after immediate simulated sleep/wake, and fresh samples after underlying capture was stopped and automatically restarted. Actual physical Mac sleep was not invoked. Other system audio was playing, so an isolated physical silence/quiet-tone check was skipped explicitly; deterministic tests verified silence/stale input sends exact black. Final firmware off and zero-brightness readback succeeded. Release build and signature verification passed.

## Version 0.1.2 — audio-only permission fix

The current backend is a public CoreAudio process tap, replacing ScreenCaptureKit completely. No display enumeration, screen pixels, microphone capture, or default-output changes are used. Healthy silence no longer recreates capture; only an explicit unavailable device/tap triggers bounded recovery. 25 automated tests passed, including the healthy no-callback silence regression and Float32/Float64 PCM checks. Binary imports confirm the process-tap API and absence of ScreenCaptureKit capture imports. A scoped independent resource/thread review found no important issues.

The local installation uses a consistent development-certificate signing identity. Signing identity changes and Apple's own audio privacy consent can still require user action; no claim is made that OS-required prompts can be suppressed.

## Version 0.1.3 — smoother 25 Hz audio

29 tests passed, adding time-aware scalar attack/release, interpolation between callback updates, dropout fade/exact-off bounds, and 25 Hz frame cadence. Audio rate is upgraded to 25 Hz once for the selected audio preset, preserving other settings. The audio-only backend remains unchanged.

Actual installed-app cadence was 50 validated frames in 2.008028375 seconds (approximately 24.900 Hz, target 25). Real tap capture recovered after simulated sleep/wake and underlying tap stop. Background system audio prevented an isolated physical silence/quiet-tone observation, which was explicitly skipped; deterministic tests verified the envelope and exact black. Final Off and brightness readback 0/255 succeeded.

## Version 0.2.0 — Beat Adapt

Actual PCM bass/high transient analysis (20 ms energy windows, advanced every 5 ms) feeds a confidence-gated tempo/phase tracker. Selected-colour main and dimmer extra-hit pulses render independently at 25 Hz. The old loudness colour mode remains separate; no new screen/microphone permission or capture backend is introduced.

35 tests passed, adding 120 BPM percussion with fills/double-trigger rejection, 120→150 adaptation, steady-tone/silence behavior, new-song history reset, selected-colour decay and old-preset compatibility. A scoped independent review found no important issues.

The local generated 120→150 BPM fixture test used an audio tap limited to its afplay process to exclude unrelated background audio. The initial run measured 120.0 then 150.0 BPM, 35 main onsets, 33/34 matching beat intervals, 35 strong selected-colour pulse groups and 442 validated USB frames. Final Off and brightness readback 0/255 succeeded. These are fixture results, not a guarantee for every song or a claim of instrument separation.

## Version 0.2.1 — groove correction

Removed grid-generated pulses and off-grid hit demotion. Added 64ms Hann magnitude novelty with adaptive band thresholds and shared85ms onset deduplication to avoid cross-band duplicates while keeping close100–125ms kick pairs. Fresh43-test suite passes, including one-to-one full-mix event timing checks for syncopation, snare-led, swing, sparse/dense, soft drums and changing tempo. Optimized48kHz analysis measured2.83ms per2s audio, max23µs per512-frame chunk. Independent scoped review found no remaining important issues after event-matching correction.

A25s global audio-only timing observation received the user's music (72 classified drum events,3 extras, tempo136.1BPM); no audio was saved and no event-labelled accuracy claim is made. Updated signed0.2.1 installed preserving preferences. User visual comparison and final off are pending; no generated fixture was mixed into their music.

## Version0.3.0 — percussion colours and temporary fingerprints

Fresh51-test suite passes. Added distinct event colours with single-colour fallback, conservative percussion focus, and real in-memory eight-band recurring-hit templates with confident-only training, three-hit probation and two families/type. Callback-gap reset reviewed/fixed/tested without capture restart. Vocal-like fixture2 false hits/8s and no learned template; defined vocal+drum mix24/24 hits/1 false; soft-drums fixture23/24/1 false. New timbre10/12 kicks accepted, two held for probation. Optimized48k computation2.995ms/2s audio, max26µs per512-frame chunk.

Installed0.3.0 global audio/USB diagnostic sent499 validated frames/20s at25Hz. Final received-music snapshot32 bass/kick,2 snare,0 high events,1 learned fingerprint; no ground-truth accuracy claim. No playback changes or audio saved. Finished firmware off, brightness0/255; normal app launched with restore off for userApply. Previous0.2.1 backed up, user settings preserved. See accompanying percussion verification/guide for limits.


## Version0.4.0 — joint event DSP

Fresh54-test suite passes, preserving the51 earlier regressions plus joint/per-class/quiet/collision checks. Expanded full-mix collision/stable-colour check also passes separately. Bass-first branching replaced by35ms joint attack/tail grouping,64ms onset spectrum plus background-subtracted32ms tail spectrum, analysis-level normalization and cross-type fingerprint corroboration. Full-mix kick+snare offsets0/10/20/30ms produce one stable recognized kick-priority group;100/125ms doubles stay separate.

Defined36-event fixtures improve correct typing26→34 (boomy),26→35 (different timbre),23→35 (quiet whole track),24→30 (verysoft drums under backing); demanding soft-case detection remains31/36, with5 misses and1 high-percussion→kick error. Vocal-like fixture remains2 false hits/8s. This is not commercial-song accuracy. Measured event-decision p50~45–50ms,p95~50–60ms,max60ms among matched fixtures; add25Hz scheduling and audio/USB buffering. Optimized48k analysis4.06ms/2s audio,max44µs per512-frame chunk. Scoped review found no important remaining issues.

Installed0.4.0 realglobal One More Time observation:497 validated RGB frames/20s at25Hz,3 kick/38 snare/0 high events,2 learned fingerprints. No saved audio or ground-truth labels. These counts may indicate snare overclassification and do not prove the song fixed. Recognized combined-group priority is stable, but masked kick evidence can still be misclassified. Finished off,brightness0/255; normal app launched with restore off for userApply. Previous0.3.0 backed up, presets preserved. See accompanying joint DSP report for before/after matrix and limits.
