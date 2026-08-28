# Changelog

## 1.3.0 — 2026-08-28

Version 1.3 turns Parrot Lab into a broader all-in-one Bebop 2 workbench while
keeping every live-video queue explicitly bounded.

### Added

- Added firmware-matched **1600 × 900** Dragon profiles for Bebop firmware
  4.4.2 and 4.7.1. The helper verifies the installed firmware and selects only
  its matching binary before touching the running Dragon process.
- Added processed H.264 recording of Parrot Lab's enhanced output, original-
  quality H.264-to-MP4 remuxing at 100%, and an optional quality-controlled
  MP4 re-encode.
- Added Apple MetalFX Spatial output through 4K, processed-resolution PNG/JPEG
  screenshots and independent enhancement controls.
- Added optional GPU repair for isolated green/odd-colour H.264 blocks and
  confidence-gated temporal mosquito-noise cleanup.
- Added experimental 900p temporal reconstruction using synchronized
  `frame_quat` alignment, Apple Vision residual optical flow, confidence
  rejection and bidirectional occlusion checks. It remains off by default.
- Added calibrated 4.7.1 900p rolling-shutter/jello correction with curved
  sensor-row timing and frame-synchronized camera orientation.
- Added VideoMetadataV2 parsing and timestamp association for synchronized
  drone/view quaternions, exposure, camera position and motion data.

### Changed

- Removed the unsustainable 1080p experiment from the interface and replaced
  it with firmware-specific 900p Modified and 900p Temporal profiles.
- Normal recording now encodes the same processed GPU output shown by the live
  view. The untouched incoming Annex-B stream remains available as a separate
  developer archive.
- Added standard macOS application, Edit, Services and Window menus plus
  developer video/settings controls.
- Release builds now compile optimized Swift files in parallel and emit a
  matching SHA-256 file beside the distributable ZIP.

### Fixed and hardened

- Latest-frame-only decode, processing and recording branches prevent slow GPU
  or disk work from accumulating live-display latency or unbounded history.
- Temporal and artifact-repair history resets safely across timestamps,
  dimensions, presets and failed/late motion estimates.
- Unsupported Bebop firmware is rejected before a patched Dragon launch, and
  stock restoration remains available through the detached helper workflow.
- The self-contained Apple-silicon release continues to verify bundled FFmpeg,
  ad-hoc signing, archive integrity and the exact post-extraction app.

### Known limitations

- Temporal reconstruction is experimental, requires decoded 1600 × 900 input
  and can reduce processed FPS on slower Macs.
- Direct production USB/libmux video transport is not implemented; video uses
  the established SkyController restream path.
- The public build is ad-hoc signed and not notarized. Parrot Lab remains a
  development workbench, not a certified flight display.

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
