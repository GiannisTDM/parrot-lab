# Experimental Sumo through the separate SC3 relay

This document covers only the older optional relay. The owned controller's
native v1c association and physical controls now work; that path does not run
the relay or listen on TCP44446. See [SC3-SUMO-NATIVE.md](SC3-SUMO-NATIVE.md)
for the native app route, prepared video observer and current validation limits.

This route is implemented and host-tested. Physical SC3/Sumo operation is not
validated. Existing direct Sumo, SC2, and ANAFI/SC3 routes remain separate.

## Prerequisites

- SC3 must already be associated with the Sumo Wi-Fi AP, with a valid local
  Wi-Fi address and route. Parrot Lab does not associate it or alter pairing.
- The separately provided SC3 relay must already be running. Its deployment is
  outside this app change; the app does not upload it, stop services, change USB
  mode, or modify firmware.
- The Mac needs a working SC3 USB network link. The current carrier is
  RNDIS/ReRNDIS; this is not a driver-free USB transport. ADB is not the video path.

See the repository's `notes/sc3-sumo-app-handoff.md` and
`notes/sc3-sumo-relay.md` for the prototype's contract and validation boundaries.
If SC3 is still paired/associated to ANAFI, resolve association separately before
trying this route; the app will not repurpose ANAFI discovery or pairing.

## Connection

Choose **Ground mode → SC3 USB relay · experimental**, enter the SC3 USB IPv4
(default **192.168.53.1**) and connect. Discovery uses TCP **44446**, never stock
mppd TCP 44444. The reply supplies `c2d_port` (relay default **54323**).

The app advertises its actual bound UDP receive port and sends every command,
event ACK, video ACK and pong from that same socket. Incoming buffer-125
ARNetwork/ARStream-1 MJPEG uses the existing direct Sumo assembler and decoder,
including negotiated fragment geometry and ACK interval. It does not use SC2
JPEG/RTP, SC3 libmux, ANAFI RTSP or H.264. No camera/FPS/quality/MTU change is made.

The relay expires after 1500 ms without a forwarded app datagram. A connected,
movement-disabled app sends ordinary neutral Sumo PCMD at 2 Hz. Authorized
piloting uses the existing 20 Hz PCMD loop; disabling movement returns to the
neutral keepalive. Relay expiry is transport cleanup, not a proven motor failsafe.

Missing-relay diagnostics identify TCP 44446 and explain the USB-link, relay and
manual Wi-Fi-association prerequisites. There is no fallback to another endpoint.

## Movement and input

**First live trial: wheels lifted, movement disabled.** Start with video and
telemetry only. Every connect/reconnect starts with movement off. Enable Mac
keyboard or an external GameController in Settings, center/release its controls,
focus the main window, then deliberately enable movement for that session.

Readiness requires an actual decoded common/Sumo state event. Valid peer
ARNetwork pings or state events then maintain a three-second freshness window;
video alone cannot authorize motion. Both the UI and serial network queue enforce
the gate, including while the UI stalls. Focus loss, input-device loss, settings
edits, stale state/heartbeat, disconnect, and reconnect clear authorization.
Fresh data never re-enables movement automatically. Tracking recovery through
this experimental route also disarms movement; following must be enabled again.

Graceful disconnect sends neutral speed/turn before closing. Old drive inputs,
follow leases and reliable jump retries cannot survive teardown/reconnect.
Device maintenance/upload/pairing tools and native SC2 mappings are disabled on
this route, including their action handlers.

Native SC3 HID mapping remains unverified. The app does not reuse SC2's mapper.
For this route, GameController admission conservatively accepts identified
external pads and excludes Parrot/SC3 and unidentified profiles. Display names
and categories are identification hints, not proof of controller provenance;
some generic external pads may require keyboard use until verified.

## Manual validation

1. With wheels raised and movement off, connect and start video. Confirm Sumo
   battery/state, **SC3 relay · experimental**, MJPEG and ARStream assembly
   counters. Sticks, keys and jump buttons must not move the vehicle.
2. Confirm missing USB link, missing relay and unavailable Sumo association fail
   clearly. No alternative discovery, pairing or service changes should occur.
3. After live state arrives, enable movement with controls centered. Test low
   forward/reverse/turn and the intended external pad. A held stick/key/jump
   button must prevent arming. Native SC3 sticks remain unverified.
4. Change focus, open Settings, unplug the input device or interrupt the relay.
   Expect movement off, neutral controls and cancelled jump retries. Inspect
   **Developer → Copy connection diagnostics**: route, session generation,
   `relayArmed`, `relayKeepalive`, pending ACKs and axes.
5. Restore data/reconnect: video/state may return, but movement must stay off
   until deliberately enabled again. Old drive/jump commands must not replay.
6. Disconnect gracefully and repeat several times. Verify neutral before socket
   close, no continuing keepalive after close, and no old-generation video/state.
7. Switch Ground relay → Air, direct Sumo, SC2 and ANAFI. Verify their prior
   routes and receiver types, with the relay gate and controller restriction off.

Hardware execution, Wi-Fi association, USB throughput/fragmentation loss, sustained
latency, real motor neutralization/watchdog behavior and SC3 HID recognition all
remain unproven. The app's stop behavior is software-tested, not a hardware failsafe
certification.

## Automated checks

`--self-test-sc3-sumo` exercises loopback discovery, segmented/unknown JSON fields,
stock fragment geometry, same UDP source port, raw large MJPEG packets, ACK/pong
routing, default-off/explicit arming, stale queue behavior with blocked UI,
neutral/expiry/reconnect, callback retirement, wrong-route/product diagnostics,
direct Sumo/SC2 regressions, input admission and route/menu/settings invariants.
The full `--self-test` includes these checks. No physical controller is contacted.
