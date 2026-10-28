# ANAFI 4K (experimental)

Open **ANAFI 4K** in the main toolbar. This workspace uses the normal production
ARSDK and RTSP services. It has its own session and camera state; Bebop, Sumo,
and MiniDrone retain their existing transports.

## Connections

| Route | Default address | ARSDK discovery | Aircraft video |
| --- | --- | --- | --- |
| Direct Wi-Fi | `192.168.42.1` | TCP 44444, Bonjour `_arsdk-0914._udp` | `rtsp://192.168.42.1:554/live` |
| SkyController 3 network | `192.168.53.1` | TCP 44444, Bonjour `_arsdk-0918._udp` | `rtsp://192.168.53.1:654/live` |

**Direct:** join the ANAFI Wi-Fi network on the Mac, then Connect.

**SC3:** pair the aircraft with SC3 normally. Connect SC3 to the Mac through a
network link macOS already exposes, then select SkyController 3. A USB cable
alone does not guarantee that macOS exposes a usable network interface. This
implementation does not install a USB driver or implement SC3's AOA/iAP2 raw
USB role adapter. If that interface is absent, the SC3 network route cannot
work yet; use Direct Wi-Fi to validate the aircraft side. An existing reachable
SC3 address can also be entered manually.

**SC3 USB bridge (preliminary):** this is a real libmux client, separate from
the network route. It discovers product `0x0918`, negotiates ARSDK v1, sends
commands on mux channel 1, and creates libmux's TCP IP proxy to `drone:554` for
the live camera. Co-piloting, telemetry, camera commands and the existing
RTSP/decoder path are shared with the network implementation.

An external USB/accessory adapter must expose a transparent duplex stream of
raw `MUX!` frames on `127.0.0.1`. Select **SC3 USB bridge**, enter that adapter's
TCP port (default **4321**, configurable), and Connect. The port is a local
adapter setting, not a service assumed to exist on SC3. Parrot Lab does not
start or install such an adapter. A bare cable is still insufficient unless
an adapter supports the controller's USB role on your Mac. No USB debug,
ADB, telnet, controller modification or RNDIS is used by this path.

The adapter boundary also accepts the existing descriptor-backed byte link
in code. On USB loss, shared controls neutralize, camera state clears, and
the video proxy closes. Reconnect creates fresh mux channels and a fresh
loopback video endpoint. Detailed state is in Copy Connection Diagnostics.

SC3 forwards camera commands while keeping its sticks in control. **Enable Mac
flight controls** explicitly requests control; PCMD begins only after the SC3
confirms piloting ownership and a known aircraft flight state is present.
Disable it to return control to SC3. Input settings/mappings use the existing
keyboard/gamepad system and neutralize inputs while editing.
Emergency motor stop uses the dedicated high-priority reliable channel and
retries while the session is alive, independently of queued camera commands.

Connect starts live video automatically. On the network routes, Start video can
also be used independently of command connection, which helps distinguish video
access from an ARSDK handshake problem. USB video needs the active mux session.
The preview uses TCP-interleaved H.264 RTP, the
existing decoder/Metal pipeline, bounded frame delivery, and RTSP keepalives.
Video failure stops the Mac recorder; it does not change aircraft flight state.

## Camera surface

Camera/gimbal IDs and permitted option combinations come from device events.
Until those events arrive, camera controls stay disabled.

- Video/photo selection; standard, hyperlapse, slow-motion, and high-frame-rate
  recording modes with correlated resolution/frame-rate choices.
- Single, bracket, burst, timelapse and GPS-lapse photos; JPEG/DNG combinations
  and full-sensor/rectilinear framing where reported as supported.
- Aircraft SD recording and capture, separate from Mac stream recording.
- HDR, Standard/P-Log/Intense/Pastel profiles, white-balance presets and EV.
- Horizon-referenced gimbal pitch, adjustable pitch speed, center, and zoom.
- Low-latency/reliable feed preferences, Mac image enhancement, focus view,
  PNG snapshots, and Mac recording converted to MP4 without another re-encode.

The live preview resolution is separate from the aircraft's SD recording
resolution: selecting 4K recording does not imply a 4K live feed. Settings are
shown from confirmed events; unsupported combinations cannot be applied.
Manual shutter/ISO, media downloading, automatic pairing, and the full
FreeFlight 6 feature set are outside this initial implementation.

## Offline validation

`--self-test-anafi` runs packet fixtures, negotiation/version rejection,
capability-list updates, camera IDs, malformed packets, ordered reliable
commands/retries/rollover, callback generation invalidation, camera UI
interaction, and loopback-only ARSDK/RTSP sessions. The loopback tests exercise
both route types, duplicate notifications, neutral controls, real asynchronous
handshakes, TCP fragmentation, RTP payload/channel negotiation, and reconnects.
No aircraft or controller is contacted by these tests.

`--render-anafi-preview /absolute/path.png` renders the disconnected workspace.
Tools → Copy Connection Diagnostics includes the ANAFI generation, route,
connection, camera, recorder, pending ACK, duplicate packet and conversion state.

`--self-test-sc3-mux` adds deterministic libmux control/negotiation fixtures,
TCP channel identity, malformed controls, late data after video closure and
flow-control ACK checks. A loopback bridge/controller emulator exercises the
actual TCP byte adapter, ARSDK ACK retry, video proxy/RTSP, piloting ownership
return and neutral input across three reconnects. It does not contact hardware.

## Live validation checklist

1. With the aircraft landed and props removed, test Direct. Within the connection
   timeout, expect the live picture, battery, Landed state, camera options and
   gimbal controls. Leave Mac flight controls off. If one branch fails, inspect
   Activity and Copy Connection Diagnostics; video can still be tested alone.
2. Repeat through SC3. Verify the Mac has access to `192.168.53.1` first. Expect
   SC3 → aircraft identity and the same camera surface. With Mac controls off,
   SC3 remains the piloting source. Failure to expose networking is a transport
   prerequisite failure, not a validated aircraft incompatibility.
3. On the bench, move pitch slowly, adjust its speed and zoom, and center.
   Change Standard/P-Log, EV and white-balance presets. Expect confirmed state
   updates and visible changes; unsupported options should be absent/disabled.
4. With a usable SD card, select a supported video combination, Apply, then
   start/stop aircraft recording. Expect recording state to confirm both changes.
   Change to Photo, apply a supported mode/file combination, and capture. Verify
   files separately on the SD card; this build does not download them.
5. Record on Mac, save a frame, stop recording, and verify the PNG/MP4 in the
   selected folder. Stop/start video repeatedly. Disconnect while recording:
   expect controls neutralized, capture finalized, and camera state cleared.
   Aircraft SD recording is independent and may continue after Mac disconnect.
6. Unplug/replug SC3 or leave/rejoin Wi-Fi. Expect command loss to clear camera
   and flight state and neutralize Mac inputs; video loss ends Mac capture.
   Reconnect must request fresh states, never reuse old camera identifiers or
   replay old input. Stream failures require explicitly restarting the stream.
7. Only after bench checks pass, validate takeoff/landing and Mac controls in a
   clear flight area. Verify SC3 ownership transfer and return, keyboard/gamepad
   mappings, and loss-of-input behavior before relying on this build for flight.
8. For USB preview, first provide the local raw-byte accessory adapter. Expect
   "SC3 libmux command channels ready", then SC3 → aircraft identity and live
   video. Diagnostics should show `ready=true`, a video channel, and `tcp=true`.
   Stop/start video: only its channel/endpoint should change; telemetry remains.
   Interrupt the adapter while holding input: controls and camera state clear,
   recording ends, and reconnect must never replay old sticks or reuse the old
   video connection. Without an adapter, expect a connection error and disabled
   controls; this is not evidence that bare USB works on macOS.

These are manual checks still required. Offline fixtures do not prove firmware
1.8.2 negotiation, real SC3 USB availability, RF latency, or camera behavior.

## Public protocol sources

- [Parrot physical connection guide](https://developer.parrot.com/docs/olympe/userguide/advanced/physical_drone.html)
- [Parrot ARSDK-ng](https://github.com/Parrot-Developers/arsdk-ng): NET JSON
  negotiation, v1 framing, reliable queues, transport IDs, and
  `libarsdkctrl/src/arsdk_device.c` TCP port resolution (aircraft service +100
  through a network-connected SC3).
- [Parrot libmux](https://github.com/Parrot-Developers/libmux): control messages,
  master/slave TCP channel routing, `drone` hostname resolution and proxy
  flow-control acknowledgements (`libmux/src/mux_channel.c`, `mux_priv.h`).
- [Parrot ARSDK XML](https://github.com/Parrot-Developers/arsdk-xml): `camera.xml`
  (feature 143), `gimbal.xml` (148), `drone_manager.xml` (137), `ardrone3.xml`,
  and `skyctrl.xml` CoPiloting/CoPilotingState (classes 20/21).
- [Parrot streaming guide](https://developer.parrot.com/docs/olympe/userguide/advanced/streaming.html)

This is a native Swift implementation of that documented subset; it does not
bundle GroundSDK/Olympe, use drone debug interfaces, or alter aircraft/controller
firmware.
