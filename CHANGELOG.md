# Changelog

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
