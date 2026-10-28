# Experimental native SC3 Sumo

Choose **Ground → SC3 native · experimental**, normally at **192.168.53.1**.
This uses native mppd's TCP44444 mobile discovery and its negotiated UDP port.
It preserves the existing controller-to-Sumo session. It never starts the older
TCP44446 relay, opens upstream Sumo discovery, or uses ANAFI RTSP/SC2 JPEG-RTP.
RNDIS/ReRNDIS supplies the current USB network carrier; ADB is maintenance only.

## Enable video permanently from Tools

Select the native SC3 route, then open **Tools → Device Tools → SkyController 3**:

- **Enable Sumo Video at Startup…** installs the verified v2f helper and a
  startup wrapper, preserving the original selector. It takes effect at the next
  SC3 restart; it does not restart anything or interrupt current controls/video.
- **Restore Startup Without Sumo Video…** restores the original native selector
  and removes the video enable marker. Native Sumo controls remain enabled.
- **Show Sumo Video Status…** reads installation state and whether the observer
  is loaded. A loaded observer is separate from actual incoming camera frames.

This supports the exact verified SC3 1.8.1 + native v1c setup. An existing root
ADB maintenance connection on local server5038 (or5037) to SC3 port9050 is needed
for these actions. The app talks directly to that existing server; it never
starts/replaces it, pairs hardware or enables debugging. ADB is not needed for
normal video after installation and is never its carrier.

Installation adds `/usr/bin/sc3-native-sumo-start-v1c` as the verified original
selector backup, replaces only `/usr/bin/sc3-native-sumo-start` atomically,
and stores v2f plus its enable marker in `/data/lib/mppd/native-sumo/video/`.
The existing init service, pinned native binary, native enable marker and original
three-launch limit remain unchanged. Video has an additional two-launch limit
per boot; missing/corrupt video or changed SDK files select controls-only startup.
The root mount returns to its previous read-only state after installation.

The app's checksums, transport/menu tests and 12 isolated install/restore/startup
fixtures pass. Read-only preflight and staged upload were verified on the actual
SC3. Persistent installation and fresh-reboot operation have not been exercised
on hardware in this pass; choose the menu action and restart the controller when
ready, with the Sumo off for that restart. Then power the Sumo and confirm actual
live video plus status showing startup enabled.

The native viewer sends only state queries, protocol ACK/pong and a Sumo video
enable request. It has no Mac PCMD, jump or ownership API. Mac driving, following,
audio commands and legacy device tools are disabled on this route. The controller
retains its existing input policy; diagnostics show reported piloting source
without claiming that the viewer can force another client's ownership away.

## Current evidence

| Layer | Verified in this pass | Still requires evidence |
| --- | --- | --- |
| Native v1c | Exact overlay/backup hashes and enabled selector preserved; corrected observer loaded alongside v1c | Physical-control/stop behavior under video load remains a manual checkpoint |
| Native app proxy | Actual linked Sumo0x0902, battery/state readiness and ACKs verified over TCP44444/UDP2233 | VideoEnable dispatch was not isolated from native automatic video startup |
| v2 observer | v2f loaded in actual mppd; negotiated 65000/4/-1, legacy transport1, raw125 forwarded over USB | Sustained load, physical-control retention and hot-plug supervision |
| Video | 222/222 real frames decoded in 15s, 640x480/about15fps; owner confirmed picture in the app | Long runs, record/disconnect and physical control under video load |
| Native mappings | Verified current defaults, separate editor and validated local draft save/backup/restore | Controller-side isolated profile apply/readback and physical button-release integration |

The working native v1c remains pinned and enabled. In the follow-up on
2026-10-27, the owner confirmed Sumo-off before each of two controller-service
restarts. The first trial exposed zero device protocol metadata; corrected v2f
reads the actual transport protocol getter and now supplies real video.
The first trial restored init-owned v1c successfully. The corrected RAM-only
foreground trial remains running for the current session. There was no startup
selector change, pairing edit or controller firmware change. Reboot/ending the
trial returns to v1c without this video extension until the startup option above
is enabled. The foreground trial is not
yet an init-supervised hot-plug deployment. No host ADB server was restarted.
The first loader probe exposed a test-program thread-exit defect; it was fixed
before the three successful normal-CRT cleanup checks.

## Video extension and diagnostics

v1c alone does **not** deliver Mac video. Start video checks for the separately
prepared **PSN2 v2 observer on UDP44447** and reports its absence precisely.
An observer heartbeat means transport availability; only complete JPEG frames
are labelled live video. Linked model is taken from a status3 native linked-drone
event, never a remembered record or a disconnected status1 event. Sumo battery
and state readiness require actual linked-drone events.

The observer copies native raw125 fragments, with negotiated size/count/ACK
interval and original frame sequencing, into an explicit versioned envelope.
The app uses its direct-Sumo assembler, bounded queues and generation/nonce
checks. Upstream reliable state ACKs remain owned by the controller. App video
ACKs, when negotiated, are bounded and drained on the native SDK loop. Stop
video retires the subscriber without disabling video for another viewer.
Proxy failure stops/finalizes local video capture; old session callbacks cannot
repopulate a new decoder or telemetry session.

**Tools → Copy Connection Diagnostics** includes native generation, negotiated
socket presence, linked product, state readiness, reported piloting source,
observer process/generation, completed/rejected frames and ACK state. Enable
existing developer diagnostics for detailed stream information.

The packaged observer inventory is recorded in
[`Resources/SC3SumoVideo/manifest.json`](Resources/SC3SumoVideo/manifest.json).
The current-boot foreground trial is hash guarded and has been run with v2f.
It restores the existing v1c init service on exit and leaves the selector intact.

## Native mappings

Open **Native SC3 mappings…** in the native sidebar or Tools menu. Current v1c
defaults are displayed first: right pitch drives, right roll steers, Takeoff
requests HIGH and RTH requests LONG. These match the current fallback mapper
readback. HIGH/repeated jump rearming still need separate physical checks.

Editor changes are explicitly **local v2 drafts**. They support logical axis
selection, inversion, deadzone/range and swapping/disabling the two existing jump
actions, with validation, atomic local save and previous-draft restore. Apply is
disabled: the current active mapper bank is shared ANAFI0x0914, and writing it
would change ANAFI. The video observer does not solve that mapping limitation.
The prepared profile/input gate still requires backend integration before
controller-side mapping changes can be enabled.

## Next bench checkpoint

1. With the Sumo physically off, review the v2 trial README, verify candidate
   hashes and run its read-only preflight. Explicitly confirm Sumo-off before
   using the foreground trial; do not change the enabled v1c startup policy.
2. Power the Sumo with wheels clear. Expect native association and linked
   model0x0902/status3, actual battery and state completion. The Mac must send
   no PCMD/jump/ownership changes. Do not jump while holding/restraining it.
3. Start video. Expect valid negotiated INFO followed by complete MJPEG frames,
   rather than merely an observer-ready indicator. If INFO appears without
   frames, inspect raw125 reception and native VideoEnable dispatch; do not
   substitute RTSP or start another upstream session.
4. Test low-speed native physical controls/release separately. Then repeat
   video start/stop, USB unplug/replug and native reconnect while recording.
   Expect capture to finalize on proxy loss, no old frames/state after reconnect,
   and bounded queues/ACKs. Video-only attachment must preserve physical control.
5. End the foreground trial and verify restoration of the pinned v1c hash,
   one init-owned daemon, enabled marker and read-only rootfs. Jumping needs
   a separate clear-floor trial. Native mapping Apply remains unavailable.

`--self-test-sc3-sumo-native` runs host fixtures and mapping checks. Existing
relay/direct/SC2 tests remain under `--self-test-sc3-sumo`. Full `--self-test`
includes both. `--probe-native-sc3 <IPv4>` is an explicit bounded diagnostic,
never part of automatic discovery or self-tests; if a Sumo is already linked it
may request video, but it never requests movement or input ownership. Add
`--native-probe-seconds 15 --native-probe-jpeg /absolute/path/frame.jpg` to
require an actual decoded frame and save the first JPEG. The diagnostic reports
received/decoded counts and actual dimensions; no frame is saved by default.

## Changed files for this integration

- New app protocol/session/tests: `SC3SumoNativeProtocol.swift`,
  `SC3SumoNativeSession.swift`, `SC3SumoNativeSelfTest.swift`.
- New native editor/local draft tests: `SC3SumoMapping.swift`.
- Existing route/UI/test integration: `SumoConnectionSelection.swift`,
  `ARSDKPhotoCapture.swift`, `AircraftSupport.swift`, `MainViewController.swift`,
  `AppDelegate.swift`, `PreviewRenderer.swift`, `main.swift`, `SelfTest.swift`.
- Controller candidate, ABI/provenance, loader and trial: new
  `tools/sc3_sumo_native_v2/`; host tests in
  `tools/tests/test_sc3_sumo_native_v2.c` and `test_sc3_sumo_native_v2_trial.py`.
- Prepared mapping component: `tools/sc3_sumo_native/mapping_v2.h`,
  `MAPPING-V2.md`, `tools/tests/test_sc3_sumo_mapping_v2.c`.
- Route documentation: this guide, `SC3-SUMO.md`, `README.md` and the historical
  `notes/sc3-sumo-app-handoff.md` / `notes/sc3-sumo-relay.md` notices.

App source filenames above are under `Sources/ParrotLab/`. The pinned v1c
payload, executable, selector, enable marker and ANAFI mapping were not edited.
