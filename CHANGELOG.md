# Changelog

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
