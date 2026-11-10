# SoundCast

Status (2026-11-10, v0.1.0 pre-release): **AirPlay 2, Sonos S1, Bluetooth
and local casting work in the app.** Tested on a Mac Pro 5,1 and an Intel
MacBook Pro (both macOS 26) with three Apple TVs, a Sonos SYMFONISK speaker
and a Bluetooth speaker.

- **One Casting switch:** turning it on switches the Mac's output to the
  **SoundCast** virtual device (HAL driver in `HALPlugin/`) and restores your
  previous output when it's turned off or the app quits. The device has its
  own volume and mute, so the Mac's volume keys and Sound menu slider work.
  If the driver isn't installed (or is out of date), SoundCast falls back to
  capturing all Mac audio with a process tap.
- **Rooms:** any local Core Audio output (built-in, wired, USB, Bluetooth),
  AirPlay 2 receivers (Apple TVs, with PIN pairing) and Sonos S1 speakers
  (live WAV over HTTP; no pairing). Tick several at once.
- **Sync:** AirPlay rooms play a fixed 2.0 s after capture; local outputs
  are held back by the same amount (minus the device's own reported delay)
  so they play together. An **AirPlay Sync** slider fine-tunes the rest, and
  **Calibrate** measures it automatically with the Mac's microphone.
- **Lip sync:** the driver reports the casting delay to macOS, so video
  players (Safari, Chrome, QuickTime) delay the picture to match. A
  **Video Sync** slider fine-tunes it.
- **Local output:** rate conversion to the device's rate (e.g. 44.1 kHz
  Bluetooth) with drift control, so Bluetooth speakers don't stutter.
- **Robustness:** AirPlay retries after a dropped session; Sonos recovers
  from dropped connections (answers its `Range` reconnects with `206`) and
  streams from a small reserve, so Wi-Fi jitter doesn't cause gaps. The
  device list follows speakers as they connect and disconnect.
- **UI:** menu bar window plus an always-on-top floating panel with live
  level meters; adjustable transparency for both. Single instance.

Known issues / not done yet: Sonos is not yet aligned with the other rooms;
two Macs casting to one AirPlay room keep taking it from each other;
receiver-initiated AirPlay stop/restart isn't handled. The app and driver
are self-signed (no notarization).

**Download:** Intel Macs can install the ready-made build from the
[Releases page](https://github.com/erer1972/soundcast/releases): unzip it and
run `bash install.sh` in Terminal. To make that zip yourself, run
`./scripts/package_release.sh` on an Intel Mac.

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
The driver publishes one device, "SoundCast", with volume and mute
controls. To remove everything: `./uninstall.sh`.

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
./dist/AirPlayDiscoverySmokeTest --sonos-volume-check 2
./dist/AirPlayDiscoverySmokeTest --sonos-volume "SYMFONISK Table lamp"
./dist/AirPlayDiscoverySmokeTest --sonos-volume "SYMFONISK Table lamp" 80
./dist/AirPlayDiscoverySmokeTest --sonos-wav 2 10
./dist/AirPlayDiscoverySmokeTest --sonos-tone "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-virtual "SYMFONISK Table lamp" 45
./dist/AirPlayDiscoverySmokeTest --sonos-sustain-silent "SYMFONISK Table lamp" 300
./dist/AirPlayDiscoverySmokeTest --sonos-reconnect "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-reconnect-silent "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-stop-probe "SYMFONISK Table lamp" 25
./dist/AirPlayDiscoverySmokeTest --sonos-start-stop-probe "SYMFONISK Table lamp" 8 80
./dist/AirPlayDiscoverySmokeTest --sonos-concurrent-stop-probe "SYMFONISK Table lamp" 8
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
`--sonos` only queries the speaker; `--sonos-volume-check` validates volume
read/write without changing it. `--sonos-volume <name>` reads volume, and
`--sonos-volume <name> <0-100>` sets and verifies it. `--sonos-wav` only serves silence;
the other speaker probes change playback. The silent probes play silence and interrupt or change the
selected source. Replace the names with your discovered receiver names. For
`--sonos-virtual` and `--dual-cast`, route audio to the main
SoundCast virtual output while the test runs. The optional final dual-cast
argument delays Sonos by that many seconds. A process-tap capture mode is also
available as `--sonos-live`, but was silent in the most recent test with the
virtual device selected as the Mac's default output.

The WAV endpoint uses a large fixed length for a live stream. A roughly
three-minute virtual-device music test completed; a separate five-minute silent
test stayed `PLAYING/OK` at 30-second intervals. On a forced connection drop,
the SYMFONISK resumed after a SoundCast retry. Simulated HTTP endpoint outages
of eight and 25 seconds also recovered automatically; these did not simulate
physical network outages. Explicit SoundCast stop, including during pending
outage retries and during startup, source change, and external Pause were
respected in silent tests. The same streamer also restarted cleanly after a
startup cancellation and after overlapping stop calls. Automatic recovery takes priority over an
external Sonos Stop and can restart playback after it. Retries are bounded;
other receiver behavior and longer outages may not recover automatically.
The mixed AirPlay and Sonos delay is manually
calibrated, not clock-synchronized. The Sonos HTTP stream allows only one
active buffer reader, so overlapping receiver requests replace the previous
reader. Longer playback, other Sonos models, and range requests remain
unverified.

## Using it

- **Casting**: one switch. On: the Mac's output moves to SoundCast and
  plays in the ticked rooms. Off: your previous output comes back.
- **Device list**: grouped "This Mac" / "Bluetooth" / "AirPlay" / "Sonos".
  Click a device to tick/untick it; tick several at once. An Apple TV that
  isn't paired yet shows **Pair…** (enter the PIN shown on the TV; each Mac
  pairs separately). A failed Sonos room shows **Retry**. Sonos speakers
  that also advertise AirPlay are listed once, under Sonos.
- **Per-device slider**: appears under a ticked device, controls that
  device's own gain (for Sonos, its own volume).
- **Master Volume**: overall gain on top of every device's own slider. With
  the SoundCast output selected, the Mac's volume keys also work.
- **AirPlay Sync**: −500…+500 ms; move right if this Mac's speakers play
  ahead of the Apple TVs, left if behind. **Calibrate** sets it for you:
  it plays a few clicks and listens with the Mac's microphone.
- **Video Sync**: −500…+500 ms on top of the delay reported to video
  players; move it if lips and voices still don't line up.
- **Transparency**: how see-through the menu and floating panel are.
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
Mac (both the Mac Pro and the Intel MacBook Pro run relaxed SIP
configurations and load it; a stock-SIP Mac remains untested), the path is:
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

- **App can't see AirPlay/Sonos devices after a rebuild** (log shows
  "Local network prohibited"): macOS ties the Local Network permission to the
  executable's build ID, which changes on every code change, even with the
  stable signing identity. Toggle SoundCast off and on in System Settings →
  Privacy & Security → Local Network, then relaunch the app.

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
