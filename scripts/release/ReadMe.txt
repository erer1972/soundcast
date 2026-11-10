SoundCast __VERSION__  (pre-release)
====================================

Plays your Mac's sound in several rooms at once: this Mac's speakers,
Bluetooth speakers, Apple TVs (AirPlay 2) and Sonos speakers.

REQUIREMENTS
- An Intel Mac (Apple silicon is not supported yet).
- macOS 15 or later.

INSTALL
1. Open Terminal (Applications > Utilities > Terminal).
2. Type  bash  and a space, drag install.sh from this folder into the
   Terminal window, and press Return.
3. Answer y, then type your Mac password when asked (nothing shows
   while you type).
SoundCast starts and its icon appears in the menu bar. When macOS asks,
allow Local Network access (needed for Apple TVs and Sonos).

USE
- Tick the rooms you want, then turn on Casting.
- Apple TV: click Pair... the first time and type the PIN shown on the TV.
- AirPlay Sync / Calibrate: line up the rooms. Video Sync: lip sync.

WHY A SCRIPT INSTEAD OF DRAG-AND-DROP
SoundCast is signed with its own certificate, not an Apple Developer ID,
so macOS would block it as coming from an "unidentified developer". The
installer clears that flag. (Without the script: open the app once, then
System Settings > Privacy & Security > Open Anyway.) The SoundCast audio
driver has been tested only on Macs running OpenCore Legacy Patcher; if
macOS refuses to load it, SoundCast still works by capturing all Mac
audio, but the Mac's volume keys and lip sync won't work.

UNINSTALL
bash  + drag uninstall.sh into Terminal, press Return.

Source code and known issues: https://github.com/erer1972/soundcast
