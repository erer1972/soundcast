# SoundCast

Status: **Phase 1 + 1.5 done. Phase 2 (AirPlay 2 sender) in progress.**

- **Phase 1:** global "cast everything" capture + local multi-output
  (built-in speakers, Bluetooth, any Core Audio device) with per-device
  and master volume, plus a menu bar UI.
- **Phase 1.5:** a system-wide virtual output device ("SoundCast" plus
  four presets) implemented as a HAL driver in `HALPlugin/`, so any app can
  send its audio to SoundCast through the normal macOS output picker.
  Installs and activates on the Mac Pro. Each preset is now an
  independent, simultaneously-active capture+output session in the menu
  bar UI — validated on real hardware with two presets casting to
  different rooms at once with zero cross-contamination (see
  `docs/DESIGN.md` §7.3).
- **Floating panel:** an always-on-top desktop panel (compact or expanded)
  with the master switch, volume and per-source / per-device controls.
  Turn it on from the menu bar ("Show Floating Panel").
- **Single instance:** launching a second copy exits immediately.
- **Phase 2 (in progress):** AirPlay discovery, PIN pairing, realtime
  streaming, and retry after a simulated session drop are implemented.
  Pairing and audible playback were validated on two AppleTV6,2 receivers;
  receiver-initiated stops/restarts and multi-room sync remain unverified.
  The in-menu pairing UI still needs a manual test. Sonos S1 discovery,
  playback control, and experimental WAV streaming are implemented in the
  backend. A CLI test played audio from the SoundCast virtual device on a
  SYMFONISK speaker; Sonos integration in the app UI remains future work.
  AirPlay-enabled Sonos receivers are not independently validated.

See `docs/DESIGN.md` for the full architecture, the research behind the
AirPlay 2 and HAL-driver decisions, and the phase plan.

Core Audio and AirPlay paths have been validated on the Mac Pro 5,1. See
`docs/DESIGN.md` for current hardware results and the remaining unverified
cases.

## Requirements

- macOS 15 or later is the Swift package deployment target; hardware
  validation has been performed on macOS 26.7.1 (Tahoe) on the Mac Pro 5,1.
- Xcode Command Line Tools (`xcode-select --install`) for `swift`,
  `swiftc`, `codesign`, `otool`.
- No Apple Developer Program membership, no notarization — by design
  (see "Code signing" below and design doc §7.2).

## Build

```sh
cd ~/soundcast   # wherever you've cloned/copied this
./build.sh
```

This will, in order:
1. Create a stable, local, self-signed code-signing identity in its
  dedicated keychain, if one doesn't already exist (one-time; you'll see a
   single authorization prompt the very first time this runs — that's
   expected).
2. `swift build -c release`.
3. **Disassemble the actual build output and fail the build** if it
   contains any AVX/AVX2/FMA/F16C instruction — the Mac Pro 5,1's
   Westmere Xeon doesn't have them, full stop. If this step ever fails,
   it means a dependency or some code path didn't actually get built
   with the Westmere baseline flags that `Package.swift` sets — it's
   telling you exactly which binary and which instruction, so you can
   track down why.
4. Assemble `dist/SoundCast.app` and sign it with the identity from
   step 1.

Build it once on the Intel MacBook, then **copy `dist/SoundCast.app`
over to the Mac Pro 5,1 and run it there too** — don't just run the
MacBook-built copy only on the MacBook and call it tested; the whole
point of the Westmere gate is that the *same binary* needs to run on
both machines. Re-running `build.sh` on the Mac Pro directly also works
and re-signs with the same stable identity either way.

## Keeping the Mac Pro in sync (if you develop on another machine)

The Mac Pro and the development machine hold separate copies of this
tree. Edits made elsewhere do not appear on the Mac Pro by themselves,
and a build there will silently use the old code. From the development
machine:

```sh
./sync.sh --dry-run   # show what differs
./sync.sh --build     # copy, then build the app and the driver on the Mac Pro
```

It refuses to overwrite files that are newer on the Mac Pro unless you
pass `--force`.

## Install the virtual device driver (Phase 1.5, optional)

```sh
cd HALPlugin
./build_and_test.sh      # build driver and diagnostic, Westmere check, sign
./install_and_check.sh   # sudo: copy to /Library/Audio/Plug-Ins/HAL, restart coreaudiod
./test_shm_flow          # plays a short sound through it and checks the shared memory
```

Installing restarts the system audio daemon, so audio cuts out briefly.
Only the main "SoundCast" device is allowed to be the system default
output; the four presets are for per-app routing and are selected in an
app's own output picker. To remove everything: `./uninstall.sh`.

## Run

```sh
open dist/SoundCast.app
```

A speaker icon appears in the menu bar. Click it, flip "Casting" on.

### The permission prompt

The first time you turn casting on, macOS will prompt for system-audio
capture permission (the same family of prompt as microphone access,
driven by the `NSAudioCaptureUsageDescription` string in `Info.plist`).
Allow it. If you ever need to reset this (e.g. after changing the
signing identity, which you shouldn't need to with the stable
self-signed cert `build.sh` sets up): **System Settings → Privacy &
Security → Microphone** (process-tap capture surfaces here) — remove
SoundCast's entry, it'll re-prompt next launch.

AirPlay discovery also needs local-network access. Allow that prompt so
SoundCast can browse and connect to receivers on your network.

### Sonos backend smoke tests

These commands use the built `AirPlayDiscoverySmokeTest` executable:

```sh
./dist/AirPlayDiscoverySmokeTest --sonos-invalid-rate
./dist/AirPlayDiscoverySmokeTest --sonos-server-start-probe
./dist/AirPlayDiscoverySmokeTest --sonos 5
./dist/AirPlayDiscoverySmokeTest --sonos-wav 2 10
./dist/AirPlayDiscoverySmokeTest --sonos-tone "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-virtual "SYMFONISK Table lamp" 45
./dist/AirPlayDiscoverySmokeTest --sonos-reconnect "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-reconnect-silent "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-stop-probe "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-switch-probe "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-external-stop-probe "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-external-pause-probe "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-long-outage-probe "SYMFONISK Table lamp" 35
./dist/AirPlayDiscoverySmokeTest --sonos-long-outage-retry-probe "SYMFONISK Table lamp" 35
./dist/AirPlayDiscoverySmokeTest --sonos-long-outage-probe "SYMFONISK Table lamp" 55 25
./dist/AirPlayDiscoverySmokeTest --sonos-long-outage-stop-probe "SYMFONISK Table lamp" 55 25
./dist/AirPlayDiscoverySmokeTest --dual-cast "kaan" "SYMFONISK Table lamp" 120 2.5
```

The first two commands test invalid sample rates and listener startup locally.
The next two only discover/query the speaker or serve silence; the others
change its playback. The silent probes play silence and interrupt or change the
selected source. Replace the names with your discovered receiver names. For
`--sonos-virtual` and `--dual-cast`, route audio to the main
SoundCast virtual output while the test runs. The optional final dual-cast
argument delays Sonos by that many seconds. A process-tap capture mode is also
available as `--sonos-live`, but was silent in the most recent test with the
virtual device selected as the Mac's default output.

The WAV endpoint uses a large fixed length for a live stream. A roughly
three-minute virtual-device music test completed. On a forced connection drop,
the SYMFONISK resumed after a SoundCast retry. Simulated HTTP endpoint outages
of eight and 25 seconds also recovered automatically; these did not simulate
physical network outages. Explicit SoundCast stop, including during pending
outage retries, source change, and external Pause were respected in silent
tests. Automatic recovery takes priority over an
external Sonos Stop and can restart playback after it. Retries are bounded;
other receiver behavior and longer outages may not recover automatically.
The mixed AirPlay and Sonos delay is manually
calibrated, not clock-synchronized. Longer playback, other Sonos models, and
range requests remain unverified.

## Using it

- **Casting toggle**: on/off for the whole capture+output pipeline.
- **Device list**: grouped "This Mac" / "Bluetooth" / "AirPlay" / "Sonos".
  AirPlay receivers are discovered and selectable; the experimental Sonos
  S1/UPnP backend is not yet selectable in the app. AirPlay-enabled Sonos
  devices may appear under AirPlay, but have not been independently validated. Click a device
  to tick/untick it; multi-select works — tick several at once.
- **Per-device slider**: appears under a ticked device, controls that
  device's own gain.
- **Master Volume**: overall gain on top of every device's own slider.
- **Launch at Login**: standard `SMAppService` toggle, no helper app.
- **Refresh Devices**: re-scans Core Audio's device list (e.g. after
  pairing a new Bluetooth speaker).

## Code signing — why self-signed, not ad-hoc or paid

Per design doc §7.2: **no Apple Developer Program membership, ever,
unless you choose to opt into it later** — this whole project is meant
to build and run with nothing but a free Apple ID (not even that, for
Phase 1) and Xcode's command line tools.

`scripts/create_local_signing_identity.sh` creates a **self-signed**
code-signing certificate once, in a dedicated `soundcast-build` keychain, and every build
reuses it. This matters specifically because of how macOS's privacy
permission system (TCC) tracks grants: a plain **ad-hoc** signature
(`codesign -s -`) has no persistent identity — every rebuild produces a
different signature hash, and TCC's stored grant is keyed to that hash,
so a rebuild can silently lose or re-prompt for the audio-capture
permission you already granted. A self-signed certificate gives a
*stable* identity across rebuilds (same cert → same signing anchor every
time), so the permission grant survives normal development iteration.

### Optional future step: paid Developer ID + notarization

Not needed for anything in Phase 1 or this README's instructions. If
you ever want to distribute `SoundCast.app` to another machine *without*
copying it there directly (e.g. via download, where Gatekeeper's
quarantine flag would apply), or if the HAL driver fails on a stock-SIP
Mac (the Mac Pro's OCLP setup has passed; the Intel MacBook remains
untested), the path is:
enroll in the Apple Developer Program ($99/yr), get a Developer ID
Application certificate, `codesign --sign "Developer ID Application: ..."`
instead of the local identity, then `xcrun notarytool submit` +
`xcrun stapler staple`. That's the full extent of what this would ever
need to become a "normal" distributed Mac app — not required for your
own use on your own two Macs.

## Uninstall

Quit the app, delete `dist/SoundCast.app` (or wherever you moved it).
If you'd enabled Launch at Login, toggle it off in the app *before*
deleting it (so `SMAppService` unregisters the login item cleanly), or
remove it manually afterward via **System Settings → General → Login
Items**.

To also remove the local signing identity (not necessary just to
uninstall the app, only if you want to clean up the keychain):

```sh
security delete-identity -c "SoundCast Local Signing" ~/Library/Keychains/soundcast-build.keychain-db
```

## Troubleshooting

- **Build fails at the Westmere check step**: see step 3 above — it
  names the offending binary and instruction. Most likely cause: a
  future dependency added without routing through `Package.swift`'s
  `westmereCFlags`/`westmereSwiftFlags`.
- **No audio from a ticked device**: check Console.app for `SoundCast`
  log lines (both `ProcessTapCapture` and `LocalOutputEngine` log via
  `NSLog` on failure). For a newly added device or path, a wrong Core
  Audio property constant can surface at runtime rather than compile
  time; the log line will say which call failed and with what `OSStatus`.
- **Permission prompt never appeared / casting silently does nothing**:
  confirm `NSAudioCaptureUsageDescription` made it into the built
  `dist/SoundCast.app/Contents/Info.plist` (build.sh copies it from
  `Resources/Info.plist` — if you edited the wrong copy, check there).
