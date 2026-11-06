# SoundCast — Design Doc v2

Status: **draft for review — no code written yet, per the agreed process.**

Changes from v1: added a system-wide virtual Core Audio output device (HAL
`AudioServerPlugIn`) so *any* app/web page can target rooms via the normal
macOS output picker, not just our own global tap; added room-preset virtual
devices; added a hard CPU-baseline constraint (Mac Pro 5,1 is a Westmere
Xeon — no AVX/AVX2) that applies to every binary we ship, especially the
HAL plugin since it runs inside `coreaudiod`.

## 0. tl;dr

| Question | Answer |
|---|---|
| Private-API shortcut to multi-device AirPlay? | **No** — confirmed (v1 §1), restricted entitlement, dead end. |
| Is the process tap private API? | **No** — public since macOS 14.2 (v1 §2). |
| Can a HAL virtual-audio driver (BlackHole-style) still be loaded on macOS 26 Tahoe with free ad-hoc signing? | **Genuinely unresolved by research — must be tested on your actual Mac, no paid account either way (your decision).** Evidence is contradictory: one report reasons `coreaudiod`'s plug-in hosting likely doesn't enforce same-Team-ID library validation (plausible — that would break every third-party driver, Developer-ID-signed ones included); but a separate real-world Tahoe report shows even a *valid, Developer-ID-signed* driver failing to be instantiated by `coreaudiod` for unclear reasons. That second data point is actually reassuring for going free: paying $99 isn't a confirmed fix either right now, this early in Tahoe's life. See revised §7.2. |
| Chosen AirPlay 2 route | Native Swift reimplementation (v1 §4), unchanged. |
| Hard new constraint | **No AVX/AVX2/FMA/F16C anywhere, ever** — Mac Pro 5,1's Westmere Xeon doesn't have it, and an illegal instruction inside the HAL plugin crashes `coreaudiod`, i.e. all audio on the Mac. See §8. |

*(§1–§6 are unchanged from v1 — private API investigation, process-tap capture, local aggregate-device output, AirPlay 2 sender approach, Sonos S1/UPnP, and cross-output sync. Reproduced below only where a new section depends on them; see v1 in git history / below for full text.)*

---

## 7. System-wide virtual Core Audio device (new)

**Status: ✅ built and validated fully end-to-end on the Mac Pro 5,1,
driver through the Swift app (2026-11-05).** `SoundCast.driver` is
installed, self-signed, loads cleanly, is recognized by the OS as a real
output device (confirmed via `system_profiler` and by Apple's own
`avconferenced`/`callservicesd` listing it). Setting it as the default
output device and playing audio writes real frames into the shared
memory ring buffer. And — the part that makes this an actual feature,
not just a working driver — `VirtualDeviceCapture` (new, in
`Sources/SoundCastCore/`) reads that same shared memory on the Swift
side and feeds `LocalOutputEngine`, confirmed by watching the local
`RingBuffer`'s `framesAvailable` jump from 0 on every play and drain
back to 0 between plays — i.e. audio sent to the "SoundCast" device was
observed flowing all the way through to a real local output. Swift can't
call `shm_open` directly (it's declared variadic; Swift refuses to
bridge any variadic C function even unused), so a tiny non-variadic C
shim target (`Sources/CSoundCastSHM/`) exists solely for that one call.

Getting the driver itself working took three fix iterations after the
initial build, each isolated by reading the actual `coreaudiod`/`afplay`
system log traces rather than guessing — recorded here since the
specific mistakes are easy to repeat:

1. **`GetZeroTimeStamp` returning an error.** The property's doc
   comment says devices without their own clock "do not need to
   implement" it; that doesn't mean erroring is safe. `AudioDeviceStart`
   failed immediately with `kAudioHardwareIllegalOperationError`
   ('nope') the first time anything tried to actually play through the
   device. Fixed by returning a benign synthetic clock (current
   `mach_absolute_time()`, sample count from frames already written)
   instead of an error.
2. **`kAudioDevicePropertyBufferFrameSize` not settable.** Host clients
   negotiate buffer size via Get *and* Set; this was a fixed constant
   with Set always rejected, so the host had no confirmed buffer size
   and the log showed `FetchAndLogFrameSize ... frame size is 0`. Fixed
   by backing it with a real variable Set actually writes, plus adding
   the paired `BufferFrameSizeRange` property.
3. **Four properties never implemented at all** —
   `kAudioDevicePropertyClockDomain`, `kAudioDevicePropertyIsHidden`,
   `kAudioDevicePropertyZeroTimeStampPeriod`, and
   `kAudioStreamPropertyTerminalType`. Found only by adding temporary
   diagnostic logging inside the driver itself (its stdout isn't
   visible to us — it runs in `coreaudiod`'s out-of-process remote
   driver host) and watching exactly which properties the HAL queried
   during IO start. `ZeroTimeStampPeriod` was the real fix:
   it's declared directly in `AudioServerPlugIn.h` itself (not just the
   general `AudioHardwareBase.h`), specifically because a plugin-hosted
   virtual device with a synthetic clock needs to declare it — its doc
   comment states a hard minimum of 10923 sample frames (used 16384).

A later deep read-through of the finished driver (not prompted by any
test failure) found two more real issues, one fixed and one deliberately
left open:
- **Fixed:** `GetPropertyDataSize` for the device's `OwnedObjects`/
  `Streams` properties always claimed 4 bytes regardless of scope, while
  `GetPropertyData` correctly returns 0 bytes for input scope (no input
  capability) — a Size/Get mismatch no test happened to exercise.
- **Open, deliberately not fixed yet:** the shared-memory segment is
  mode `0666` (world read-write) — necessary since the driver runs as
  `_coreaudiod` while the app runs as the interactive user, but it means
  any local process could write into it, including the header fields a
  reader has to trust. Not fixing this blindly since there was no Swift
  reader yet to verify a tighter scheme against; now that
  `VirtualDeviceCapture` exists and validates header fields against
  known-good constants before trusting them (§7.1 below), this is
  mitigated but not eliminated — worth revisiting if this project ever
  runs on a genuinely multi-user machine, which it doesn't today.

### 7.1 Architecture

A HAL `AudioServerPlugIn` bundle, `SoundCast.driver`, installed to
`/Library/Audio/Plug-Ins/HAL`, loaded by `coreaudiod` (requires
`sudo killall coreaudiod` after install/update — standard for this driver
class, same as BlackHole/BackgroundMusic/Loopback). It declares one virtual
output device named **"SoundCast"**, which is then visible everywhere the
OS surfaces Core Audio output devices: System Settings → Sound, Control
Center's Sound menu, Option-click on the menu-bar volume icon, and every
per-app output picker that uses the standard device list (Music, Spotify,
Zoom, and browsers via `setSinkId`, since that call is just selecting a
Core Audio device under the hood on macOS).

Data path: the driver's `DoIOOperation` callback (realtime, hard deadline —
no blocking syscalls, no allocation) writes incoming PCM into a **lock-free
ring buffer in a POSIX shared-memory segment** (`shm_open` with a
well-known name, sized generously, e.g. a few seconds of 48kHz stereo
float32). The SoundCast menu-bar app maps the same segment and reads from
it on its own thread — same shared-buffer design already used internally
between capture and the output branches (v1 §6), just with the producer
now living inside `coreaudiod` instead of inside our own process.

**Precedent, and where I'm diverging from it**: `BackgroundMusic`
(kyleneideck) is the closest existing open-source project to this
shape — a HAL driver + a companion app that receives the driver's audio.
Its actual IPC is mostly ordinary **HAL property-change notifications**
(the driver flips a property, the app's existing HAL observer reacts) plus
a narrow **XPC helper service** used only for startup synchronization — it
does *not*, as far as its public source shows, move the live audio samples
themselves through shared memory; property notifications aren't a
sample-accurate data path. Since our requirement is literally "move audio
samples from inside coreaudiod to our app," I'm proposing shared memory
for the sample data itself (realtime-safe, no syscall per sample) and
reserving **XPC for control/handshake only** (device list, which preset is
active, start/stop, buffer-ready signaling) — mirroring BackgroundMusic's
split of "XPC for coordination, something else for the real-time path"
rather than copying its exact mechanism. ([BackgroundMusic
DEVELOPING.md](https://github.com/kyleneideck/BackgroundMusic/blob/master/DEVELOPING.md),
[BGMXPCHelper](https://github.com/kyleneideck/BackgroundMusic/blob/master/BGMApp/BGMXPCHelper/main.m))

Mute/loopback: the driver should present as a normal output device with no
special "silence" requirement — whatever's written to it is immediately
available to our app, which then fans it out to the ticked rooms exactly
like the global-tap path (v1 §3–§6), just with a different capture source.

### 7.2 Code signing — no paid account, decided; go/no-go test result

**Decision (yours): no Apple Developer Program membership, no notarization,
ever, unless you opt into it later purely as an optional README step.**
Everything below is built to work entirely locally, for free.

**Go/no-go test result on the Mac Pro 5,1 (2026-11-05): GO, with an
important caveat.** Built and installed a minimal, self-signed, zero-device
`AudioServerPlugIn` (`HALPlugin/` — see `driver.c`, implementing the full
23-function vtable copied field-for-field from this Mac's actual Xcode
26.5 SDK header, not from memory) to confirm empirically whether
`coreaudiod` would load a self-signed HAL driver on Tahoe at all. Result,
straight from the system log around the install:

```
kernel: AMFI: '...SoundCastNullDriver': local signing public key not initialized
amfid:  ...SoundCastNullDriver not valid: Error Domain=AppleMobileFileIntegrityError
        Code=-423 "The file is adhoc signed or signed by an unknown certificate chain"
...
coreaudiod: Creating remote driver service: SoundCastNullDriver.driver, pid: 26050
```

AMFI **does** reject the self-signed binary — confirming the community
reports from §7.2's original research were right, and pinning down the
exact mechanism (an "unknown certificate chain" check, the same bucket
ad-hoc signing falls into). **But the rejection is only logged, not
enforced, on this specific Mac** — `coreaudiod` spawned the driver into
its own out-of-process host anyway (confirmed: that process stayed alive,
set up its XPC connections cleanly, no crash), almost certainly because
of this machine's relaxed, OCLP-driven SIP configuration (§7.2's earlier
`csrutil status` finding) — the same log-but-don't-enforce pattern
already seen once before in Phase 1 (the audio-capture TCC grant that
appeared pre-approved with no visible consent dialog).

**This does not necessarily transfer to the Intel MacBook.** If that
machine runs stock, unmodified SIP (likely, since it probably didn't need
OCLP root patches), AMFI's rejection there may well be *enforced* rather
than just logged — meaning the self-signed driver could fail to load at
all on that machine even though it works here. **The same go/no-go test
needs to run on the MacBook before concluding this works everywhere** —
see `HALPlugin/build_and_test.sh` + `install_and_check.sh`, same two-step
split (build+sign needs no sudo, install+restart does and needs to be run
by hand, not through an agent, since it needs a sudo password).

Also worth noting as a side discovery, unrelated to our own driver: this
same log output caught two *pre-existing* issues with this Mac's own
built-in Apple HAL drivers — `AirPlay.driver` failing a `dlsym` symbol
lookup, and `MacAudio.driver` being the wrong architecture (`arm64e` vs
the `x86_64` this Mac needs). Neither is something this project caused or
needs to fix, but worth knowing this Mac already has some non-stock audio
driver state from before we started.

**Signing identity: self-signed, not ad-hoc, created once by `build.sh`.**
This is the right call for exactly the reason you gave — ad-hoc signing
(`codesign -s -`) produces a signature with no persistent identity at all;
every rebuild gets a new hash, and TCC's stored grant (the audio-capture
permission prompt) is keyed to that hash, so every rebuild would re-prompt
or silently lose the grant. A **self-signed code-signing certificate**
(Keychain's "Self Signed Root" + "Code Signing" type, generated once,
stored in the login keychain) gives a stable signing identity: re-signing
with the *same* self-signed cert across rebuilds keeps the designated
requirement's anchor constant, so TCC's grant survives rebuilds. This
doesn't need to be publicly trusted or chain to Apple at all — TCC only
cares that the anchor is stable, not that it's trusted the way a real CA
would be. `build.sh` will: check `security find-identity -p codesigning -v`
for an existing `SoundCast Local Signing` identity, generate one via
`security create-keypair`/`Certificate Assistant` scripting if missing,
then use it for every `codesign` call in the build — app bundle, HAL
plugin, and any helper binaries alike, so they all share one stable
identity.

**Free Apple ID "Personal Team" cert — considered, not chosen.** This
alternative (an "Apple Development" certificate tied to a free
Apple-ID-registered Team ID, via Xcode, no $99) does give an
Apple-issued-chain identity rather than a local-only one, which research
suggests macOS's keychain ACL system treats slightly differently (some
reports say Apple-issued Team IDs avoid a repeat keychain-access prompt
after the first "Always Allow" in a way a self-signed identity may not,
for keychain items specifically — not confirmed for TCC audio-capture
grants, which is our actual concern here, and the self-signed reports for
*that* specific permission type are positive). Personal Team certs also
drag in an Apple-ID/Xcode-account dependency this project otherwise has
none of. Going with self-signed as primary, per your stated preference —
if we hit a self-signed-specific wall during testing, Personal Team is the
documented next thing to try before giving up on the driver entirely (see
fallback ladder below), not a change to the current plan.

**The part that's still genuinely unknown: does `coreaudiod` on Tahoe (via
OCLP) load a self-signed or ad-hoc `AudioServerPlugIn` at all?** I looked
for an authoritative answer and didn't find one — research surfaced
real but *contradictory* community evidence:

- One line of reasoning (an open spike issue on a similar project) argues
  `coreaudiod`'s plug-in-hosting process likely runs without Hardened
  Runtime's Library Validation (same-Team-ID matching) enabled, since
  turning that on would break loading for *every* third-party HAL driver
  that doesn't share Apple's own Team ID — including already-working,
  properly Developer-ID-signed ones. If true, "signed with *something*
  verifiable" (self-signed included) may be all `coreaudiod` ever actually
  required, historically.
- But a separate, real Tahoe user report (Sonarworks/SoundID's HAL driver)
  shows the opposite symptom for the *opposite* reason: a driver that
  **is** validly Developer-ID-signed (`codesign -dvvv` clean) still never
  gets instantiated by `coreaudiod` on Tahoe, for a cause the reporting
  thread doesn't pin down. If a paid, correctly-signed driver can still
  fail to load on Tahoe, the blocker may not be about signature *class*
  at all — it could be a new Tahoe-specific approval gate (e.g. something
  like the Security & Privacy "Allow" step System Extensions already
  require), a bundle-format expectation that changed, or a plain
  regression. This is actually useful news for going free: it means
  paying wouldn't obviously have bought a guarantee either, this early in
  Tahoe's life — so there's no clearly-safer paid alternative being
  passed up.
- Both README sources also flag a practical install-time step regardless
  of signing tier: strip the `com.apple.provenance` extended attribute
  after copying the driver bundle into `/Library/Audio/Plug-Ins/HAL`
  (`xattr -d com.apple.provenance SoundCast.driver`) — `install_driver.sh`
  does this unconditionally.

**Phase 1.5 therefore starts with a short, deliberately narrow go/no-go
test before any real feature code is written**, so we find out which
world we're in cheaply:

1. Build the smallest possible `AudioServerPlugIn` (declares one silent
   device, does nothing else), self-sign it with the stable local
   identity above, install it, `sudo killall coreaudiod`.
2. Check `system_profiler SPAudioDataType`, System Settings → Sound, and
   `log show --predicate 'process == "coreaudiod"'` around the restart
   for whether it's seen/instantiated at all, and what `coreaudiod` logs
   if not.
3. If that fails, rebuild the *same* minimal plugin ad-hoc-only (isolates
   "self-signed specifically" vs. "any non-Apple signature" as the
   variable) and repeat step 2.
4. If both fail, try the free Personal Team cert as a second, still-free
   identity class, repeat step 2.
5. **If all three fail**: §7 (the system-wide virtual device) is shelved
   as not achievable without paid signing on Tahoe today, full stop — no
   workaround chase, no SIP-weakening, nothing exotic. The product
   fallback is **§2's global process-tap "cast everything" mode, which
   doesn't depend on any of this and is unaffected either way** — it's
   why Phase 1 (tap mode + local multi-output) ships and is a complete,
   usable product *before* Phase 1.5 is attempted at all (§10). The README
   documents the paid Developer ID + notarization path purely as "if you
   ever want the system-wide virtual device and local signing didn't work
   for you, this is the $99/yr path" — nothing more, per your instruction.

I'm not spending Phase 1.5 effort on shared memory, XPC, or room presets
until step 2 (or 3/4) of that test actually succeeds on your hardware —
building those out against an untested loading assumption would be
wasted work if the answer turns out to be "no."

### 7.3 Room presets as additional virtual devices

**Status: ✅ static fallback built and validated (2026-11-05)** — went
with the static table, not dynamic `CreateDevice`, given how much
iteration even the *one* original device needed (§7.2's three-fix
chase) made the less-traveled dynamic-creation path too risky to
attempt first. `driver.c` was rewritten around a `gDeviceSlots[5]` table
(main + 4 presets), each with its own device/stream object IDs, name,
UID, and — critically — its own independent shared-memory segment.
Confirmed on real hardware: all 5 appear correctly in
`system_profiler SPAudioDataType` with correct channel/sample-rate/
transport info; driving real audio into "SoundCast - Preset 1"
specifically (via the same set-default-output + `afplay` technique)
moved only that preset's write counter — isolated a prior confusing
result (two counters showing the same numbers) down to leftover state
from earlier manual test calls in the same session, not any actual
cross-device leak: re-tested cleanly (read preset1's counter, drive
audio into preset1 only, re-read main's counter) and confirmed main's
counter does not move at all when only preset1 is used.

The Swift side now has `VirtualDevicePreset` (one of 5, mirroring the
driver's table — same "must stay in sync by hand" caveat as the shared
memory layout itself) and `VirtualDeviceCapture` takes one as a
parameter instead of a hardcoded shm name. The menu bar UI has a second
picker (shown only in virtual-device mode) to choose which preset this
session reads from.

**Update (2026-11-06): the full simultaneous-multi-session vision is now
built and validated.** `AppState` was rewritten around a
`[CastSource: RunningSession]` dictionary — the global tap and each of
the 5 virtual-device presets are independent sources, each with its own
on/off state, device selection, and gains; the menu bar UI presents each
as its own expandable, independently-toggleable section.

Validated on real hardware by running two `VirtualDeviceSmokeTest`
processes concurrently for 15s (preset1 → Built-in Output, preset2 →
the Bluetooth speaker "Neohipo BP10"), driving audio into each at known,
logged real-world timestamps. Mapping each drive command's real
timestamp onto both sessions' own internal elapsed-time polling logs
showed *zero* cross-contamination: preset1's ring buffer only saw
activity around the times audio was driven into preset1, preset2's only
around its own drive command, and a third drive command sent after
preset1's session had already ended correctly produced no activity at
all.

One artifact worth recording so it isn't mistaken for a bug later: a
single preset's own activity sometimes showed as two separate bursts a
few seconds apart in the polling log. Traced to the test harness, not
the product — one `test_shm_flow` invocation always does two sequential
`afplay` plays, and real `afplay` duration plus per-step overhead can
stretch that across several seconds, showing up as two polling bursts
from what was really one drive command.

Original plan, superseded above for the "which approach" question, kept
for context: additional devices named e.g. `SoundCast - Living Room`,
`SoundCast - Living + Kitchen`, created/removed from the menu bar app, so
different apps can simultaneously target different rooms.

Two ways to implement this, differing in risk, and I want to flag the
uncertainty rather than assume the nicer one just works:

- **Dynamic (ideal)**: the driver calls the host's device-creation
  interface (`AudioServerPlugInHostInterface`'s create/destroy-device
  calls) at runtime when the user adds/removes a preset in the menu bar,
  and notifies the HAL via a `kAudioPlugInPropertyDeviceList`
  property-changed notification so the new device appears live everywhere
  (System Settings, app pickers) without restarting `coreaudiod`. This
  matches how the API is documented to work, but I have **no way to test
  this from here** (no macOS access at all in this session), and dynamic
  add/remove of HAL devices post-load is a less-traveled part of the API
  than static declaration — I'd treat this as "try first, have a fallback
  ready" rather than a given.
- **Static fallback**: the driver declares a fixed, modest number of
  preset device slots at load time (e.g. `SoundCast`, `SoundCast - Preset
  1` .. `SoundCast - Preset 4`), always present in the system device list.
  The menu bar app controls what room-group each active preset slot maps
  to via the XPC control channel; unused slots just sit inertly in the
  device list (acceptable — BlackHole ships 3 fixed channel-count variants
  the same way, so a handful of always-visible "SoundCast - Preset N"
  entries isn't out of step with how this class of driver already behaves
  in practice). Renaming a slot at runtime to a user-chosen label (vs. a
  generic "Preset 1") depends on whether `kAudioObjectPropertyName` is
  settable live for this device type — again, needs on-Mac testing, not
  something I can confirm statically.

I'll build and test the dynamic approach first once we're actually on your
Mac in Phase 1.5, and drop to the static fallback immediately if it
doesn't behave — this is called out explicitly so "it behaves exactly like
the brief" isn't silently assumed going in.

### 7.4 Install/uninstall script

`install_driver.sh` / `uninstall_driver.sh` (separate from the main
`build.sh`, since driver install needs `sudo` and a `coreaudiod` restart —
you should be able to re-run the main app build without re-touching the
system driver each time):

- Install: copy `SoundCast.driver` to `/Library/Audio/Plug-Ins/HAL/`,
  `chown root:wheel`, strip `com.apple.provenance` (§7.2), `sudo killall
  coreaudiod`.
- Uninstall: remove the bundle, restart `coreaudiod` again. Mirrors
  BlackHole's and BackgroundMusic's documented install pattern.

---

## 8. Hard constraint: Westmere baseline, no AVX anywhere (new)

The Mac Pro 5,1's Xeon is Westmere: **SSE4.2 is the ceiling, no AVX, no
AVX2, no FMA, no F16C.** A binary built on the Intel MacBook (likely a
newer-generation CPU with AVX2 available) must still run correctly on the
Mac Pro, and the HAL plugin specifically runs *inside `coreaudiod`* — an
illegal-instruction fault there doesn't just crash our app, it takes down
system audio on the whole Mac. This gets a hard, non-negotiable rule set:

- **Never** pass `-march=native`, `-mavx`, `-mavx2`, `-mfma`, or `-mf16c`
  to any compiler invocation, Swift or C, anywhere in the build.
- **Pin the target explicitly** rather than trust defaults: Swift via
  `-Xcc -march=westmere` (or equivalently constrain via `-target-cpu`
  where `swiftc`/SwiftPM expose it) and any vendored C (SRP6a, and later
  any ALAC/FLAC/Opus encoder or resampler we end up vendoring for the
  Sonos/AirPlay paths) built with `-march=westmere` as well — Westmere is
  a real Clang/LLVM `-march` target name and is the right one to pin to,
  rather than leaving it at whatever the build machine's default is.
- **Libraries with their own runtime CPU dispatch are fine as-is**:
  Accelerate.framework and CryptoKit both do their own runtime
  feature-detection internally and will not emit AVX instructions into
  *our* binary — the risk is specifically code *we* compile, not Apple's
  frameworks.
- **`build.sh` gets an automated verification gate**, not just a
  compiler-flag promise: after building every binary and the HAL plugin,
  disassemble each one (`otool -tvV` or `objdump -d`) and grep for VEX-prefixed
  instructions and `%ymm`/`%zmm` register mnemonics; **fail the build** if
  any are found, naming the offending binary and symbol so it's obvious
  what to fix (usually: a dependency or vendored source built without the
  `-march=westmere` flag actually reaching it).
- **Runtime guard, defense in depth**: at startup (menu bar app) and at
  driver load (HAL plugin), read `sysctl hw.optional.avx1_0` and
  `hw.optional.avx2_0`, log the result either way (so a future "why did
  audio die on the Mac Pro" report has the CPU feature line right there in
  the log), and — since the build-time gate should already make this
  unreachable in practice — treat a *mismatch* (AVX-coded binary on a
  non-AVX machine) as a logged hard-fail-fast rather than a silent crash:
  better to refuse to load with a clear log line than to let `coreaudiod`
  take an illegal-instruction trap.

This applies to **every** phase, not just §7 — the AirPlay 2 crypto/TLV8
code and any Sonos-side audio-format handling are equally in scope the
moment any of them pulls in vendored C or a SIMD-friendly library. I'll
bake the `-march=westmere` flag and the `otool`/`objdump` check into
`build.sh` from Phase 1 onward, not bolt it on later.

---

## 9. Open questions carried over from v1 §7, plus new ones from §7/§8

- (v1, unresolved) WAV vs. compressed for the Sonos HTTP stream — defaulting to WAV per your note that v1's defaults are fine.
- (v1, unresolved) "other Macs" = macOS's built-in AirPlay Receiver feature — assumed yes per your note that v1's defaults are fine.
- **(resolved)** Signing: self-signed local identity, no paid account, no notarization — §7.2.
- **(new, answered empirically in Phase 1.5 step 1, not something to decide now)** Whether `coreaudiod` on your Tahoe/OCLP setup actually loads a self-signed (or ad-hoc, or free-Personal-Team) `AudioServerPlugIn` — genuinely unknown until tested on your hardware, §7.2's go/no-go test.
- **(data point, Mac Pro 5,1, recorded ahead of Phase 1.5)** `csrutil status` on the Mac Pro: "Custom Configuration" — `Apple Internal`, `Kext Signing`, and `Filesystem Protections` disabled (expected: OCLP's standard root-patch requirement for this machine's unsupported GPU); `Debugging Restrictions`, `DTrace Restrictions`, `NVRAM Protections`, and `BaseSystem Verification` remain **enabled**. This is a partial SIP relaxation, not a blanket one — note that `Kext Signing` governs kernel extensions specifically, not the userspace code-signature/AMFI checks that actually gate whether `coreaudiod` accepts a signed Mach-O bundle like a HAL plugin, so this reading doesn't by itself predict §7.2's go/no-go outcome. Still need the equivalent check on the Intel MacBook, and still need the actual Phase 1.5 test regardless of either machine's SIP posture.
  - Confirmed directly via SSH: `sw_vers` reports macOS **26.7.1** (build `25G241`); CPU is a **Xeon W3680 @ 3.33GHz** (Westmere), with a feature-flag list topping out at **SSE4.2** and no AVX/AVX2/FMA/F16C present anywhere in it — directly validating §8's constraint is real, not precautionary.
- **(new, not blocking, your call whenever)** Are you already building with Xcode / a specific Swift toolchain on the MacBook, or do you want `build.sh` to assume only Apple's bundled `swift`/`swiftc` from Xcode Command Line Tools (simpler, fewer moving parts, and sidesteps any question of a separately-installed toolchain's own default `-march`)?

## 10. Revised phase plan

Reordered so the feature least exposed to the Tahoe driver-signing
uncertainty (§7.2) ships and gets proven on real hardware first:

1. **Phase 1 — ✅ DONE, confirmed working on the Mac Pro 5,1 (2026-11-05).**
   Capture (global process tap, "cast everything" mode, v1 §2) + local
   multi-output (private aggregate device, per-device gain, master
   volume, v1 §3) + menu bar UI skeleton (device list grouped by
   category, checkboxes; AirPlay/Sonos categories show up but with no
   live discovery wiring yet). `build.sh` ships with the Westmere
   baseline flags and the `otool`/`objdump` AVX-scan gate from day one
   (§8) — verified against real compiled output on the real Westmere
   Xeon, not just the compiler flags. Fully public-API, no-signing-drama
   path, as predicted — no entitlement or paid-signing issues hit.
   Validated via two purpose-built CLI smoke-test tools
   (`LocalOutputSmokeTest`, `CaptureSmokeTest` — see §7.2-adjacent
   `Sources/`) that exercise the real Core Audio code headlessly: found
   and fixed one real bug along the way (`AudioBufferList`'s C
   "struct hack" variable-length array was being copied by value,
   corrupting any buffer past the first when 2+ devices were targeted —
   fixed with Apple's `UnsafeMutableAudioBufferListPointer` overlay).
   Final end-to-end run captured real system audio and rendered it to
   all 5 of the Mac Pro's discovered local devices simultaneously
   (Bluetooth speaker + 3 built-in outputs + a virtual loopback device),
   confirmed audible by you directly. One open oddity, not blocking:
   the system audio-capture permission was already granted with no
   consent dialog either of us saw — possibly this Mac's relaxed,
   non-stock SIP configuration; worth watching for a real prompt on the
   Intel MacBook, which likely runs stock SIP.
2. **Phase 1.5** — HAL `AudioServerPlugIn` virtual device (§7), self-signed,
   no paid account. Starts with §7.2's narrow go/no-go test (minimal
   silent plugin, self-signed, confirm `coreaudiod` actually instantiates
   it on your Tahoe/OCLP machine) *before* writing the real feature. Only
   if that passes: single `SoundCast` device, shared-memory audio path,
   XPC control channel, install/uninstall script (incl. the
   `com.apple.provenance` strip). Room presets (§7.3) and the
   dynamic-vs-static device-creation question follow once the
   single-device case is proven working. If the go/no-go test fails
   outright (self-signed, ad-hoc, and free Personal Team all rejected by
   `coreaudiod`), §7 is shelved and we move straight to Phase 2 with
   Phase 1's tap mode as the shipped, complete product.
3. **Phase 2** — AirPlay 2 sender: discovery, pairing, RTSP/RTP streaming,
   starting with your Apple TV (v1 §4).
4. **Phase 3** — Sonos S1 (SSDP/UPnP/HTTP) + AirPlay-2-capable Sonos
   (reuses Phase 2's sender) + Launch at Login + final sync/delay-trim UI
   polish (v1 §5, §6).

I'll check in with you after each phase, as before — and specifically
before starting Phase 1.5's code, once §7.2 and the `csrutil status`
question are answered.

## 11. Phase 1.5 status and findings (2026-11-06)

**Working on the Mac Pro 5,1 (macOS 26.7.1):** the self-signed `SoundCast.driver`
installs, `coreaudiod` loads it, all five devices (`SoundCast`, `Preset 1-4`)
activate, and `HALPlugin/test_shm_flow` passes (frames reach shared memory).
The app builds, is signed, and passes the Westmere AVX gate.

**Not yet verified on hardware:** sustained playback (minutes of music) with the
rewritten device clock; the app-side chain end to end (virtual device -> ring ->
`LocalOutputEngine` -> speakers); the floating panel; the single-instance guard.

### Findings worth remembering

- **The driver runs out of process.** On this macOS, `coreaudiod` does not load
  the bundle itself: the log says "Creating remote driver service ...
  SoundCast.driver, pid N" and the plug-in lives in its own sandboxed process
  ("Core Audio Driver (SoundCast.driver)"). `shm_open` still works from there
  (confirmed), but any future file/IPC access must be checked against that
  sandbox. Driver-side failures are logged with `syslog` as "SoundCast driver:".
- **Device clock.** `GetZeroTimeStamp` is derived from elapsed host time since the
  first `StartIO`, in whole multiples of `kDeviceZeroTimeStampPeriod` (16384
  frames). It must not be derived from how much audio was written: the host
  schedules IO from this clock, so that is circular.
- **Property queries must honour the qualifier.** `coreaudiod` asks a device for
  its streams and its controls with the same `OwnedObjects` selector and a
  qualifier listing class IDs. Returning the stream for every qualifier made it
  treat the stream as a control and throw ("creating a control with invalid
  class ID 0"), and the devices never activated. Fixed by filtering on the
  qualifier and answering `ControlList` with an empty list. Unknown properties
  now return `kAudioHardwareUnknownPropertyError`, as the HAL expects.
- **Only the main device may be the default output.** With all five
  default-eligible, `coreaudiod` chose "SoundCast - Preset 2" as the system
  default output on its own after a restart, silencing the Mac. Presets now
  report `CanBeDefaultDevice` / `CanBeDefaultSystemDevice` = 0; apps can still
  select them in their own output pickers. (Open question: whether presets still
  appear in System Settings -> Sound with that flag off.)
- **Shared memory.** The ring is created on the first `StartIO` and is reused, not
  unlinked, across restarts (an app that already mapped it keeps working). It is
  `fchmod`ed to 0666 so the non-root app can open it read-only. A stale segment of
  a different size is replaced. `StartIO` fails loudly if the ring can't be made.
- **The smoke tests and menu must never offer the SoundCast devices as render
  targets** (feedback loop); `LocalDeviceEnumerator` filters UIDs starting with
  `com.soundcast.device`.
- **The Mac Pro and the development machine are separate copies.** Edits made on
  the dev machine did not reach the Mac Pro on their own, and earlier "passing"
  runs used stale code. Use `./sync.sh` (see README) before building there.

### Added since the original Phase 1.5 plan

- Floating always-on-top desktop panel (`FloatingPanelController.swift`,
  `WidgetPanelView.swift`), a compact and an expanded layout sharing `AppState`.
  A real WidgetKit widget is still to be tried; it may be blocked by the
  self-signed identity (App Groups / extension signing).
- Single-instance guard: a second `SoundCast.app` exits at launch.
- `AppState` retries every second while a virtual-device source waits for the
  driver to create its ring ("Waiting for audio to be played to ...").
- `HALPlugin/uninstall.sh`, `sync.sh`.

### Still open for Phase 1.5

- Sustained-playback and app-chain verification (above).
- XPC control channel between app and driver (not started; presets are currently
  five fixed slots).
- Behaviour across sleep/wake, `coreaudiod` crashes, and non-48 kHz clients.

## 12. Phase 2 plan: AirPlay 2 sender (draft for review, no code yet)

Goal: tick an Apple TV (later HomePods, other AirPlay 2 speakers) in the menu
bar list and hear the same audio the local devices play, with the local
outputs delayed to match.

### 12.1 What the research says (and does not say)

Sources: the unofficial [AirPlay spec](https://openairplay.github.io/airplay-spec/print.html)
(AirPlay 1 / RAOP era, still the best field reference for `_airplay._tcp` and
`_raop._tcp` TXT records), the [UxPlay AirPlay2 protocol wiki](https://github.com/FDH2/UxPlay/wiki/AirPlay2-protocol),
shairport-sync's [pair_ap library](https://git.sudo.is/mirrors/shairport-sync/src/branch/master/pair_ap)
(a C implementation of the HomeKit-style pairing, written for the *sender* side
by the OwnTone author), the [openairplay2 receiver](https://docs.rs/crate/openairplay2/latest/source/README.md),
and [pyatv's supported-features page](https://postlund.github.io/pyatv/documentation/supported_features).

- **AirPlay 2 pairing is HomeKit (HAP) style:** `pair-setup` (SRP-6a, Curve25519,
  Ed25519) then `pair-verify`, giving a shared secret. Some devices accept
  *transient* pairing with no PIN (standard code `3939`); others need a PIN
  shown on screen. After pairing, RTSP runs inside a ChaCha20-Poly1305
  encrypted channel carrying binary plists, and audio packets are individually
  ChaCha20-Poly1305 encrypted. Audio is ALAC or AAC. Timing uses PTP.
- **pyatv only does legacy RAOP audio** (AirPlay 1 style pairing). It has been
  verified on Apple TV 3 and Apple TV 4K gen 1, and lists HomePod, but states HAP
  authentication for RAOP is not implemented. A newer Apple TV or HomePod may
  refuse legacy RAOP, so legacy-only is not a safe bet.
- **PTP:** one open receiver skips PTP for single-output use. That is the
  receiver side; what a *sender* must provide (clock master, which ports,
  whether an Apple TV insists on it) is **not established by this research** and
  is the biggest unknown. Mark it as "to be learned from packet captures".
- **Not found:** an official spec; sender-side nonce/framing details for
  encrypted RTSP and audio; any confirmed, current open-source *sender* that
  streams audio to Apple TV 4K over AirPlay 2 (OwnTone's status could not be
  confirmed from search). Expect to read pair_ap and OwnTone source and to
  capture traffic from a real sender (Music app / System Settings) against
  your Apple TV.

### 12.2 Approach (native Swift, as decided in v1 §4)

Split into milestones, each independently shippable and testable:

| # | Milestone | Risk | Verifiable by |
|---|-----------|------|---------------|
| 2a | **Discovery.** Browse `_airplay._tcp` / `_raop._tcp` with `Network.framework` (`NWBrowser`), parse TXT (`features`, `flags`, `pk`, `model`, `pw`), fill the existing `airplayDevices` list. Devices appear in the menu but cannot be played to yet. | Low | Apple TV shows up with the right name and model |
| 2b | **Protocol capture.** Capture a real macOS-to-Apple-TV session (Wireshark/`tcpdump` on the Mac Pro) to settle PTP, stream types, ports, encoder, pairing mode. Writes up findings in this doc before any streaming code. | Medium (information, not code) | Findings recorded |
| 2c | **Pairing + encrypted RTSP.** SRP-6a (3072-bit), HKDF, X25519/Ed25519, ChaCha20-Poly1305 framing. CryptoKit provides everything except SRP; SRP needs big-integer arithmetic, either a small vendored C bignum built with the Westmere flags or a Swift implementation (one-time per pairing, so speed is irrelevant). | High | Pair-verify succeeds against the Apple TV |
| 2d | **Audio stream.** Encode from the existing ring buffer (AudioToolbox `AudioConverter`, ALAC or AAC-LC, 48 kHz stereo to match the HAL device), packetize, encrypt, send, run the timing/clock exchange the capture says is needed. | High | Audio audible on the Apple TV |
| 2e | **Integration + sync.** Third consumer of the capture ring (per v1 §6): AirPlay has ~2 s of buffering, so delay the local outputs to match and expose a per-device delay trim. Keeps working with the global tap and the virtual-device sources. | Medium | Local and Apple TV audio line up by ear, then by a click-track measurement |

Plan: do **2a and 2b first** and report back before committing to 2c/2d.
2c/2d are where the project can fail, so we find out cheaply whether the Apple TV
accepts transient pairing and what it wants for timing before writing crypto.

### 12.3 Constraints that apply here

- **Westmere baseline (§8):** all new code, including any vendored C, builds with
  the existing `westmereCFlags` / `westmereSwiftFlags`; `build.sh`'s AVX scan stays
  the gate. System frameworks (CryptoKit, AudioToolbox) are Apple's and already run
  on this Mac Pro.
- **Privileges:** PTP normally uses UDP 319/320. Modern macOS allows non-root
  wildcard binds to low ports, but this is **unverified on the Mac Pro** and must
  be tested in 2b/2d. If not, a different approach (device-side clock, or a helper)
  is needed.
- **Permissions:** local network access prompt (`NSLocalNetworkUsageDescription`,
  `NSBonjourServices` for `_airplay._tcp` and `_raop._tcp`) must be added to
  `Resources/Info.plist`; the self-signed identity (§7.2) should keep the grant
  stable across rebuilds, as with audio capture.
- **No private API, no paid account** (unchanged).

### 12.5 Status (2026-11-06): 2a done, 2c partially done and verified

**2a (discovery) — done, validated on real hardware.** `AirPlayDiscovery.swift`
browses `_airplay._tcp` via `NWBrowser`. One real gotcha: plain
`NWBrowser.Descriptor.bonjour(type:domain:)` resolves endpoints but its
`Result.metadata` always comes back `.none` — getting the TXT record (needed
for `model`/`features`/`pk`) requires the dedicated
`.bonjourWithTXTRecord(type:domain:)` case instead, confirmed against the real
Network.framework swiftinterface on the Mac Pro after the plain form silently
found devices with empty metadata. Found "Living Room" (excluded per policy),
"kaan", and "Sonos" on the real LAN with correct model/feature parsing.

**2c (pairing) — pair-verify done and verified; pair-setup implemented but
not yet verified live.** This took real detective work, recorded here so it
isn't repeated:

- The actual AirPlay control connection uses the receiver's **IPv6
  link-local address** (`fe80::...`), not its IPv4 address — five separate
  `tcpdump` attempts filtered on IPv4 found nothing but mDNS chatter despite
  confirmed real audio playing, until checking `netstat -an` on the Mac Pro
  directly revealed the real `ESTABLISHED` connection was `tcp6` to a
  `fe80::` address. AWDL (Apple's peer-to-peer Wi-Fi) was a red herring —
  tried and ruled out before finding the real answer.
- Captured a real pair-verify exchange (macOS's own AirPlay sender talking to
  an already-paired Apple TV) and decoded it byte-for-byte: M1 = TLV8
  `{State=1, PublicKey=<32 bytes>}` (37 bytes total), M2 = TLV8
  `{EncryptedData=<120 bytes>, State=2, PublicKey=<32 bytes>}` (159 bytes),
  M3 = TLV8 `{EncryptedData=<120 bytes>, State=3}` (125 bytes), M4 = TLV8
  `{State=4}` (3 bytes). Matches public HAP research exactly. The real
  sender tried `X-Apple-HKP: 6` first, got a 6-byte TLV8 rejection
  (`Error=4, State=2`), and fell back to `X-Apple-HKP: 3`, which succeeded —
  this is a protocol-version negotiation header, not part of the TLV8 body.
- Implemented in `Sources/SoundCastCore/`: `TLV8.swift` (codec),
  `AirPlayRTSPConnection.swift` (RTSP-over-TCP, Content-Length framed, shared
  by pair-verify/pair-setup/future RTSP SETUP+RECORD), `AirPlayIdentity.swift`
  (persistent Ed25519 keypair + pairing ID, stored in Application Support),
  `AirPlayPairVerify.swift`, `AirPlayPairSetup.swift`, `SRP6a.swift` (needs
  correct 3072-bit modular exponentiation for pair-setup; added
  `attaswift/BigInt`, a well-known MIT-licensed dependency, rather than
  hand-rolling that — approved explicitly rather than assumed).
- **Pair-verify is fully verified against real hardware**, not just "it
  compiled": ran the real Swift implementation against both the Apple TV and
  the Sonos speaker. Both cleanly rejected it with TLV8 `Error=2`
  (Authentication) — exactly the expected outcome, since SoundCast's identity
  has never been paired with either device. Critically, reaching that clean
  rejection required the implementation's ChaCha20-Poly1305 decryption of the
  server's M2 `EncryptedData` to actually succeed first (wrong HKDF
  salt/info strings or nonce construction would have thrown an AEAD
  authentication failure before ever getting that far) — real cryptographic
  interop confirmed, not merely "no exception was thrown."
  One real-world gotcha fixed along the way: a bare pair-verify POST (just
  `Content-Type`) gets a `500` with an empty body from a real Apple TV;
  matching real senders' `X-Apple-HKP`, `X-Apple-Client-Name`, and
  `X-Apple-PD` headers was required to get a real `200` with a real TLV8 M2.
- **Pair-setup is implemented from public research only — not yet verified
  live.** Every live attempt this session was rejected by the receiver's own
  access-control gate before the SRP exchange itself ever ran: the Apple TV
  returned a custom `470 Connection Authorization Required`, the Sonos
  speaker a plain `403 Forbidden` — even after setting the Apple TV's "Allow
  Access" to "Anyone on the Same Network." A genuine `/pair-pin-start` does
  work (confirmed: triggered a real 4-digit PIN on the TV's screen), but
  pairing still wasn't unlocked by that alone with the headers/sequencing
  tried so far — there is more to the real flow than two sequential RTSP
  calls. Treat every SRP/TLV8/HKDF constant in `AirPlayPairSetup.swift` as a
  documented hypothesis, not a confirmed fact, until a live run succeeds.

### 12.6 Questions that change the plan

1. Which Apple TV (model, tvOS version) and which speakers do you want to cast to
   first? A HomePod, an older Apple TV, and a current Apple TV 4K can behave very
   differently (legacy RAOP vs full AirPlay 2).
2. On that Apple TV: Settings -> AirPlay and HomeKit -> *Allow Access* (Everyone /
   Anyone on the Same Network / Only People Sharing This Home) and whether a
   password/PIN is required. This decides whether transient pairing is even possible.
3. Is the Apple TV on the same subnet as the Mac Pro (no VLAN/mDNS reflector in
   between)? Discovery in 2a depends on it.
