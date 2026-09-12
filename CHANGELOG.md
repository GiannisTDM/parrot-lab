# Parrot Lab release notes

## V1.6 — 2026-09-12

- Sumo gamepad steering now uses a cubic response after deadzone/range
  normalization: gentle turns near center, full selected turn at the endpoint.
  The curve follows remapped turn actions; drive speed and aircraft axes retain
  their existing response.
- Removed the unused fixed-2× MetalFX image-rendering path, obsolete routing
  wrapper, unused capability/accessor helpers and unused controller state.
  Consolidated video-mode selection and controller tuning bounds, moved input
  self-tests out of runtime control code, and unified old-profile decoding.
- Fixed truncated app-originated Sumo high-jump commands: jump type is now
  encoded as the SDK's four-byte little-endian enum. Added independently
  remappable Long jump for keyboard/gamepad, initially unassigned, preserving
  existing bindings. Both jump actions appear only in Ground Mode mappings.
- Gamepad sticks learn separate directional ranges after a full sweep and
  release, allowing asymmetric controllers to reach the selected speed/turn
  limits. Ranges are isolated per connected gamepad and reset on disconnect.
- App builds now verify and reinstall locally by default. Distributable ZIPs
  are rebuilt only with `scripts/build-app.sh --release`.
- Sumo tools now tunnel script uploads and Telnet commands through the selected
  SC2 to Sumo's own IP. Uses a temporary exec/telnet session and a downstream shell
  handshake, not the old port-2324 relay hard-wired to Bebop. Direct mode retains
  direct FTP/Telnet. Script transfers are chunk-acknowledged and checksum-verified.
- Build 15 replaces the raw nc hop with SC2's native Telnet client, matching the
  working manual connection and handling downstream Telnet negotiation on SC2.
  Device commands still wait for the unique downstream shell response.
- Corrected Sumo's launcher/preflight to /bin/DragonStarter.sh, preserving its
  motor-stop-on-exit behavior instead of bypassing the stock wrapper.
- Tools now switches between Air and Ground actions instead of leaving aircraft
  tools greyed out. SC2 uploads, driver install, discovery, mappings and a new
  SC2-only RF enable/restore workflow remain available in both modes.
- Ground Tools uploads start_sumo_b29.sh beside an existing B29,
  verifies the launcher, sets executable permissions and queues a detached launch.
  No binary replacement or persistent boot modification. Launch queued is not
  a claim that Dragon startup has been verified after the link drops.
- Added a separate Sumo RF Lab script with radio/NVM diagnostics and the
  owner-confirmed EPA2 / PD14 profile at /lib/firmware/brcm/bcm43526.nvm.
  Only those two values change; other calibration/power/identity fields remain
  untouched. Restore requires the verified preserved original, never guessed
  stock values. Ground Tools can apply/restore it and queue a Sumo-only reboot.
  SC2 RF controls remain independent and retain their existing tested profile.
- Added Settings → Configure SkyController 2 sticks & buttons. Uses native
  ARSDK mapper feature 138, not Mac gamepad remapping or stick interception.
- Reads the controller's active mapping bank, current axis/button assignments
  and physical axis inversions. Supports Bebop/BB2 and the patched SC2 Sumo
  speed/steering/High Jump/Long Jump aliases. Shared Sumo/Bebop 1 banks are labeled.
- Writes one explicit selection at a time, waits for matching mapper state
  readback (not just UDP ACK), and requires Reload after an uncertain timeout.
  Disconnected/direct sessions and airborne aircraft cannot edit SC2 mappings.
- Bumped app identity to 1.6.0. Settings now scroll to their full content height.
- Added a preliminary Bluetooth MiniDrone workspace for Mambo-class drones,
  including battery/flight-state reporting, keyboard and macOS GameController
  input, and accessory-aware grabber/cannon actions. Flypad is not supported
  in this release and live MiniDrone flight/accessory validation remains
  outstanding.

## V1.5

- Added Video → Sumo · 720p + 30→45 FPS Optical Flow for direct and SC2 MJPEG.
  The independent ground preset uses image-only bidirectional flow, conservative
  temporal history, photometric/occlusion rejection and a generated midpoint
  for every two real frames. No IMU or Bebop calibration is used.
- Ground temporal output follows the same bounded display/processed recording
  path and scales to 720 pixels high with MetalFX (GPU Lanczos fallback), preserving
  aspect ratio: 640×480 becomes 960×720, not stretched 1280×720. Disable the preset
  to restore the regular scaler. Ground tuning is saved separately in Settings.
- Interpolation is suppressed for non-30-FPS cadence and missing-frame gaps;
  resolution changes/reconnect gaps reset history. Actual FPS remains measured,
  not promised by the target. Added offline ground cadence/output/reset checks.
- Air ↔ Ground now crossfades the toolbar and inspector with a subtle directional
  settle and coordinated color transition, without freezing or fading live video.
- Added gentle panel, Focus view, activity drawer and air/ground color transitions.
  Animations respect macOS Reduce Motion and never run on incoming video frames.
- Redesigned the cockpit with a two-row connection/capture toolbar, refined
  blue and copper themes, large battery/signal/FPS/output readouts, and compact
  flight overlays. Ground HUD labels now reflect the actual direct or SC2 route.
- Added Focus view to hide the telemetry inspector, expandable stream and
  Dragon profile details, collapsible navigation/controller panels, and an
  expandable activity drawer that keeps the latest event visible when closed.
- Moved the editable RTP port into Stream details and added a Configure controls
  shortcut. Ground mode no longer displays aircraft temporal diagnostics.
- Checked both themes at 1180 × 720 and larger window sizes, including expanded
  diagnostics and the focused camera layout.
- Added a prominent Ground Mode switch and an app-wide brown ground-vehicle
  theme without forking the application.
- Added Jumping Sumo product `0x0902` and direct `_arsdk-0902._udp` discovery.
- Corrected Ground Mode to default to the Sumo's `192.168.2.1` address while
  keeping the host field editable and remembering a custom address.
- Added the native JumpingSumo project-3 speed/turn PCMD and project-3/class-18
  video-enable command, with 20 Hz keyboard and macOS GameController control.
- Generalized legacy ARStream1 reassembly into codec-neutral completed frames:
  BB1 continues through Annex-B H.264 while Sumo uses bounded MJPEG decoding.
- Sumo video shares Parrot Lab's existing enhancement, MetalFX, processed
  screenshot and processed H.264 recording paths.
- Ground Mode hides flight, GPS, SC2 health, Dragon and RF panels and gates all
  aircraft-only commands and writes. RF modification remains BB2-only.
- Added native ARSDK Tools actions for Bebop/BB2 flat trim and start/stop
  magnetometer calibration, including landed-state safety gating and live
  X/Y/Z calibration progress/error reporting.

## V1.4 — 2026-08-28

- Added first-class Bebop Drone (BB1) support through the same native ARSDK
  transport as BB2: stock video, telemetry, flight control, camera control and
  genuine fisheye JPEG capture work through SC2 or direct Wi-Fi.
- Aircraft model is derived from the SC2 `ConnexionChanged` product ID, or the
  official direct `_arsdk-0901` / `_arsdk-090c` Bonjour service. The detected
  model, route, firmware and model-specific media filename prefix are reflected
  in the UI and logs.
- BB2-only Dragon 900p, calibrated camera correction, persistent-Telnet and
  RF/MOD actions are disabled for BB1 and unknown products; unknown aircraft
  retain only safe stock ARDrone3 capabilities.
- Residual temporal flow now runs at a selectable reduced resolution after IMU
  alignment, then scales vectors into the full-resolution temporal resolve.
- Forward and reverse flow requests run concurrently to remove the previous
  full-resolution sequential-flow bottleneck.
- Optional motion-compensated midpoint generation adds one synthetic frame for
  every two real frames, targeting a bounded 45 FPS display and recording.
- An automatic flow-resolution governor preserves a 30 FPS minimum target by
  reducing residual-flow cost before sacrificing real-frame cadence; reverse
  flow is computed only on midpoint-generation intervals in 45 FPS mode.
- Generated frames use a dedicated 45 Hz bounded presentation queue and a
  lower-cost GPU scaling path so they no longer block or arrive late behind
  the real-frame display path.
- Generated display and processed-recording queues remain explicitly bounded;
  overload drops frames instead of increasing FPV latency.
- Added mutually exclusive standalone BB1/BB2 mode with direct TCP 44444
  discovery, discovery-returned command UDP routing, direct ARStream2 port
  advertisement, and stock `MediaStreaming.VideoEnable`.
- Added universal native macOS GameController support for Xbox, PlayStation and
  MFi pads, plus fully remappable app-focused keyboard actions.
- Added SC2-equivalent 20 Hz PCMD, acknowledged take-off/land/RTH handling,
  camera orientation commands, configurable stick deadzone/limit/inversion,
  and automatic neutral input on focus, controller, route or connection loss.
- Emergency remains deliberately unassigned by default.

## V1.3 — 2026-08-28

V1.3 turns Parrot Lab into a practical all-in-one Bebop 2 workbench while
keeping every live-video queue explicitly bounded.

### Highlights

- Firmware-matched 1600 × 900 Dragon profiles for Bebop firmware 4.4.2 and
  4.7.1, with the unsustainable 1080p experiment removed from the UI.
- Processed H.264 recording: the normal recording contains Parrot Lab's
  enhanced/MetalFX output and the 100% MP4 option remuxes it without another
  lossy generation.
- Apple MetalFX Spatial output through 4K, independent image-enhancement
  presets, and processed-resolution PNG/JPEG screenshots.
- Optional H.264 repair for isolated green/odd-color blocks and temporal
  mosquito noise.
- Experimental 900p temporal reconstruction using synchronized `frame_quat`
  alignment, Apple Vision residual optical flow, confidence rejection and
  bidirectional occlusion checks. Tuning remains off by default under
  **Parrot Lab → Settings**.
- Calibrated 4.7.1 900p rolling-shutter/jello correction with curved sensor-row
  timing and frame-synchronized camera orientation.
- Native ARSDK telemetry through the SkyController 2 for battery, flight state,
  GPS, attitude and camera state, plus stock Dragon 4K fisheye capture and
  unchanged JPEG download.
- One-click deployment/update tools for Dragon Video, persistent Bebop Telnet,
  RF/MOD Suite and the SkyController 2 Apple-NCM driver patch.
- Four distinct live-rate diagnostics: encoded access-unit FPS, unique RTP
  timestamp FPS, decoded-frame FPS and display refresh FPS.

### Reliability and distribution

- Latest-frame-only decode/processing/recording branches prevent slow GPU or
  disk work from growing live-display latency or retaining an unbounded frame
  history.
- Self-contained Apple-silicon release ZIP with bundled FFmpeg, ad-hoc signing,
  signature/archive verification and a matching SHA-256 file.
- Standard macOS application, Edit, Services and Window menus; no Apple account,
  paid certificate, provisioning profile or secret is required to package it.

### Known limitations

- The public build is ad-hoc signed and not notarized. Follow the first-launch
  steps in [README.md](README.md).
- Temporal reconstruction is experimental, requires decoded 1600 × 900 input
  for activation, and may reduce processed FPS on slower Macs.
- Direct production USB/libmux video transport is not implemented; the current
  video path uses the established SkyController restream route.
- Standalone piloting and direct ARStream2 setup are implemented from the
  confirmed protocol but still require ground-only hardware validation.
- Parrot Lab remains a development workbench, not a certified flight display.
