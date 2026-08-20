# Parrot Lab

Parrot Lab is an early macOS ground-station and diagnostics app for the Parrot
Bebop 2 and SkyController 2. It talks directly to the controller over USB,
shows the drone camera with a live HUD, and exposes the radio and flight data
we have been using to reverse-engineer the platform.

> **Beta:** this is experimental software for bench testing and development.
> Do not use it as your only flight display or safety system.

![Parrot Lab HUD preview](docs/images/parrot-lab-preview.png)

## What works

- Direct Apple Silicon Mac-to-SkyController 2 networking over USB-A
- Live Bebop 2 H.264 video relayed by the SC2
- RF chain RSSI, average RSSI, noise, SNR, link quality and PHY rate
- Flight state, distance, altitude, roll, pitch and yaw
- SkyController 2 and Bebop 2 battery telemetry
- RTP bitrate, packet-loss and jitter diagnostics
- Offline replay/demo and built-in self-tests

Parrot Lab is observational: it does not change RF, Dragon, or flight-control
configuration automatically.

## Tested setup

- Apple Silicon Mac running macOS 13 or newer
- SkyController 2 firmware 1.0.9 (Linux 3.4.11+)
- Bebop 2 connected to the SkyController 2
- Homebrew FFmpeg for the Bebop's cyclic-intra-refresh H.264 stream

Other versions may work, but the included SC2 kernel module is tied to the
tested kernel. Do not load it on a different kernel build without rebuilding
and validating it.

## How it fits together

```text
Parrot Lab on macOS
    |  Apple private NCM over USB (192.168.53.0/24)
    v
SkyController 2 (192.168.53.1)
    |-- TCP 23    SC2 telemetry
    |-- TCP 7711  video-restream setup
    |-- UDP 55004 H.264/RTP video
    `-- TCP 2324  read-only Telnet relay to the Bebop 2
                         |
                         `-- Wi-Fi to 192.168.42.1
```

## Install the SC2 support files

The SC2 must already have Telnet access. Copy the contents of [`sc2`](sc2) to
a writable FTP directory on the controller, then run as root:

```sh
cd /data/lib/ftp/internal_000/parrot-lab-sc2
chmod +x install.sh test.sh unload.sh uninstall.sh
./install.sh
reboot
```

The installer temporarily remounts `/` read/write, installs one short boxinit
service named `plboot`, restores the root filesystem to read-only, and starts:

- the Apple-NCM module needed for Mac USB networking;
- a TCP 2324 relay used only to read drone telemetry.

After reboot, connect the Mac to the SC2 USB-A port. The Mac should receive a
`192.168.53.x` address and should be able to reach `192.168.53.1`.

For a non-persistent test, run `./test.sh ./apple_mac_ncm.ko` instead. See the
[SC2 notes](sc2/README.md) for verification, removal and the persistence bug
that led to the current installer.

## Build and run the Mac app

Install the decoder and build the app:

```sh
brew install ffmpeg
./scripts/build-app.sh
open "$HOME/Applications/Parrot Lab.app"
```

In Parrot Lab, leave the SC2 address at `192.168.53.1`, connect, and start the
video receiver on UDP port `55004`.

Developers can run the test suite directly:

```sh
swift build
.build/debug/ParrotLab --self-test
```

The build script creates an ad-hoc-signed app in `~/Applications` and a zip in
`dist/`. FFmpeg is discovered from Homebrew at runtime. A custom executable
can be embedded by setting `PARROTLAB_FFMPEG=/absolute/path/to/ffmpeg`; anyone
redistributing such a bundle is responsible for complying with FFmpeg's
license and the licenses of the enabled codecs.

## Safety and recovery

- Back up the SC2 before installing or editing system files.
- Do the first test on the bench with props removed and the aircraft grounded.
- Keep a working Telnet path until USB networking has been verified after a
  full reboot.
- Run `/data/lib/parrotlab/uninstall.sh`, then reboot, to remove persistence.
- Loading a kernel module built for another kernel can crash the controller.

## Background and acknowledgements

This work was partly inspired by the community-authored
[*An unofficial Bebop drone hacking guide 1.7.2*](https://fargesportfolio.com/wp-content/uploads/2018/01/BeebopHackingGuide1_7_2.pdf).
Its documentation of the Bebop's Linux filesystem, Telnet/FTP access and open
developer tooling remains excellent background material.

Parrot, Bebop and SkyController are trademarks of their respective owner. This
project is independent community research and is not affiliated with Parrot.

## License

The Parrot Lab app and original project files are released under the
[MIT License](LICENSE). The adapted Linux Apple-NCM driver retains its
upstream GPL-2.0-or-BSD-2-Clause choice; see
[third-party notices](THIRD_PARTY_NOTICES.md).
