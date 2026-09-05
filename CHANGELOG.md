# Changelog

## 1.5.0 — 2026-09-05

Version 1.5 adds an experimental Jumping Sumo ground workspace, a major cockpit
redesign and a dedicated bounded temporal path for MJPEG ground video.

### Added

- Added Jumping Sumo product `0x0902`, direct `_arsdk-0902._udp` discovery and
  the product's native project-3 speed/turn PCMD and video-enable commands.
- Added codec-neutral ARStream1 assembly: BB1 continues through Annex-B H.264,
  while Sumo uses bounded MJPEG decoding through either direct Wi-Fi or the
  experimental SC2 JPEG restream.
- Added a Sumo-specific **720p + 30→45 FPS Optical Flow** preset with image-only
  bidirectional flow, photometric/occlusion rejection and aspect-correct
  scaling. A 640×480 source becomes 960×720 rather than being stretched.
- Added native flat-trim and magnetometer-calibration actions for Bebop/BB2,
  with landed-state gating and live X/Y/Z progress and error reporting.
- Added remappable Jumping Sumo ground controls, including High Jump.

### Changed

- Redesigned the cockpit with distinct blue air and copper ground themes, a
  two-row connection/media toolbar, larger key readouts and compact overlays.
- Added Focus view, expandable stream/profile/controller/navigation panels and
  an activity drawer that preserves the latest event while collapsed.
- Air/ground transitions now crossfade UI chrome without fading or blocking
  live video, and respect macOS Reduce Motion.
- Ground mode defaults to `192.168.2.1`, remembers a valid custom host and
  hides or gates aircraft-only flight, GPS, Dragon and RF controls.
- Ground temporal preferences are stored independently from the Bebop temporal
  profile. Missing frames, reconnect gaps, resolution changes and non-30-FPS
  cadence suppress interpolation and reset history safely.
- Forward/reverse temporal work and generated display/recording remain
  explicitly bounded; overload drops work instead of increasing FPV latency.

### Experimental Sumo/SC2 support

- Added the current matched experimental artifacts for SC2 `mppd`, SC2
  `libarsdk.so` and the Jumping Sumo B29 30 FPS Dragon patch.
- Installation is manual in 1.5. The Sumo must also be added manually to the
  SC2 known-drone configuration as model 2306 (`JS`) with its exact SSID and
  open security. An integrated installer is planned.
- The Sumo supports the same RF/MOD mechanism as the other Broadcom/SKY-based
  Parrot products, but stock backups and local RF limits still apply.
- Physical SC2 control and Parrot Lab keyboard/gamepad control must not be
  enabled together: their simultaneous PCMD streams fight each other.

### Known limitations

- Jumping Sumo support, particularly routing through a patched SC2, remains
  highly experimental and requires manual device modification.
- Direct production USB/libmux transport is not implemented; SC2 video uses
  the established restream route.
- The public build is ad-hoc signed and not notarized. Parrot Lab remains a
  development workbench, not a certified vehicle-control application.

## 1.4.0 — 2026-08-29

Version 1.4 adds first-class Bebop Drone support, guarded standalone aircraft
control and a faster, bounded temporal-video pipeline.

### Added and improved

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

### Known limitations

- Standalone piloting and direct ARStream2 setup follow the confirmed Parrot
  protocol but still require careful, props-off hardware validation before use.
- Direct production USB/libmux video transport is not implemented; the current
  video path uses the established SkyController restream route.
- Temporal reconstruction remains experimental and can reduce processed FPS on
  slower Macs despite the new automatic governor.
- The public build is ad-hoc signed and not notarized. Parrot Lab remains a
  development workbench, not a certified flight display.

## 1.3.0 — 2026-08-28

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

## 1.2.0 — 2026-08-26

### Added

- Added a persistent ARSDK connection through the SkyController 2 for
  structured drone/controller battery, flight state, attitude, GPS fix,
  satellite count, speed and last-known GPS coordinates.
- Added direct stock-camera **4K fisheye** capture. Parrot Lab requests the
  original full-sensor JPEG through ARSDK and downloads the unmodified image
  from the drone.
- Added the **Image Enhancement** menu with source, denoise, clarity,
  low-light cleanup, high-quality 2× upscale and 2× upscale + clarity modes.
- Added guided SC2 address discovery through the Bebop, local USB-network
  discovery, and automatic discovery fallback during SC2 driver installation.
- Added a guarded RF power workflow for applying the tested profile to both
  devices or restoring their preserved stock baselines, with backups,
  verification and controlled reboots.
- Added detailed encoded, decoded and display frame-rate diagnostics plus RTP
  duplicate-packet accounting.

### Improved

- Expanded and reorganized the native Tools menu for Dragon Lab, persistent
  Telnet, RF/MOD deployment, RF profile control, SC2 discovery and the SC2
  Apple-NCM driver patch.
- Replaced periodic drone-battery Telnet scraping with persistent ARSDK state
  delivery at controller RF range.
- Hardened Bebop and SC2 uploads with device-aware paths, digest validation,
  explicit executable permissions and clearer completion markers.

### Fixed

- Fixed several installer failures caused by BusyBox command differences,
  incomplete PATH values, incorrect permission handling and ambiguous root
  mount-state detection.
- Fixed macOS-side video decoding issues involving FFmpeg pipe shutdown,
  duplicate RTP pictures, cyclic-intra-refresh frame delivery and diagnostic
  captures missing SPS/PPS parameter sets.
- Fixed RF Lab non-interactive profile application, stock-baseline recovery
  and reliable operation on the BusyBox environments used by both devices.

> **Known 1.2 limitation:** the custom modified-binary mode and patched 1080p
> Dragon profile are not functional in this release and should not be used.
> Unified Bebop firmware support for 4.4.2 and 4.7.1 is being developed for
> version 1.3. Stock video, telemetry, media capture and the other tools remain
> available.

## 1.1.0 build 6 — 2026-08-22

### Added

- Added **Tools → Enable Persistent Telnet on Bebop 2** for firmware 4.4.2.
  The verified, reversible installer enables the stock developer-network
  startup path so Telnet and ADB return after a reboot.

### Improved

- Improved the Bebop- and SC2-side installers so profile uploads and device
  completion markers are handled reliably rather than being confused with
  echoed shell input.
- Improved direct-Bebop and SC2-relay connection probing and added support for
  the Bebop's native battery-percentage log format.

### Fixed

- Fixed Dragon profile launches in the Bebop's minimal Telnet environment by
  resolving the firmware `setsid` executable explicitly before starting the
  detached worker.

> **Security warning:** persistent Bebop Telnet provides passwordless root
> access to devices on the aircraft network. Use it only on trusted private
> networks. The app displays removal instructions after installation.

## 1.1.0 — 2026-08-21

### Added

- Added **Custom · modified binary** to Dragon Lab for validated custom Dragon
  arguments while keeping the executable fixed to the bundled modified binary.
- Added Base64 argument transport with matching validation on macOS and the
  drone. Shell metacharacters are rejected, `eval` is never used, and custom
  input cannot select another executable.
- Added recovery-aware UI state: relay loss after a Dragon operation reports
  as expected, and fresh telemetry confirms that the replacement recovered.

### Changed

- Preset, custom and stock-restore operations now queue a detached drone-side
  worker before stopping Dragon. The worker survives the expected SC2/Telnet
  relay loss and completes the replacement launch locally on the Bebop 2.
- The release packager now bundles and rewrites FFmpeg's complete non-system
  library closure so the distributed decoder is portable without Homebrew.

> **Upgrade required:** run **Tools → Install/Update Dragon Lab on Bebop 2**
> once after updating so the drone receives the new detached helper.

### Fixed

- Fixed the remaining live-stream memory growth. Video buffers are now bounded
  and compacted while streaming instead of only releasing memory after the
  stream stops.
- Fixed Dragon restarts failing when killing Dragon also terminated the SC2
  Telnet relay before the replacement launch command could be delivered.

## 1.0.0 beta — 2026-08-21

### Added

- Lossless H.264 video recording and PNG/JPEG photo capture.
- Stock 480p and 720p stream profiles plus an experimental 1080p lab mode.
- Adjustable 1–16 Mbit/s stream bitrate with adaptive and locked modes.
- Integrated installers for Dragon Lab, the Bebop/SC2 RF-MOD Suite, and the
  SkyController 2 Apple-NCM driver patch.
- A new application logo and expanded live video/HUD controls.
- A verified ad-hoc-signed macOS distribution ZIP and reproducible release
  packaging workflow.

### Improved

- Polished the interface and consolidated device tooling into the native app.
- Added transfer verification and landed-state safeguards to device installs
  and Dragon runtime controls.

### Fixed

- Fixed a major decoded-frame memory growth bug by bounding and reusing video
  buffers instead of continually retaining consumed data.
- Fixed the Bebop 2 battery percentage failing to refresh.
- Fixed several smaller video, telemetry, installer, and UI issues.
