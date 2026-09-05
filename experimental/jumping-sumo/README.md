# Experimental Jumping Sumo support

> [!CAUTION]
> This patch set is experimental, manually installed and capable of making the
> SkyController 2 or Jumping Sumo temporarily unbootable if a file is copied to
> the wrong path or with the wrong permissions. Keep verified byte-for-byte
> backups and a tested recovery route before replacing anything. Parrot Lab
> 1.5 does not install or roll back these files automatically.

## Control-source warning

When the Sumo is connected through the SC2, choose exactly one control source:

- To drive with the physical SC2, disable Parrot Lab keyboard and gamepad
  controls.
- To drive from Parrot Lab, leave the physical SC2 sticks and buttons idle.

Using both at once sends competing PCMD streams. The alternating movement and
neutral commands cause choppy, stop-start driving.

## Matched 1.5 artifact set

| Device | Repository file | Target path | SHA-256 |
| --- | --- | --- | --- |
| SC2 | `sc2/mppd` | `/usr/bin/mppd` | `a7dd0577d1ff1861df149c3f40cce6cceb3cdcb4c96faf25d735b8980a474426` |
| SC2 | `sc2/libarsdk.so` | `/usr/lib/libarsdk.so` | `7de496934b99a5e26c34d6a4d8549cf63eebcb263b7fa9849bbc5f31f3bb58fc` |
| Jumping Sumo | `sumo/dragon-prog-B29` | `/usr/bin/dragon-prog` | `804dbc2b3dffecf564b2f3aec20caa3b0572a140d660bdbe377cff0d3d10d62b` |

Use these three files together. Do not combine them with earlier `mppd`,
`libarsdk` or Dragon experiments. The B29 Dragon build uses the proven Q16
ordering, stock transport geometry and a paced 30 FPS target.

The files are derived from Parrot firmware and are not covered by this
repository's MIT license; their original ownership and licensing remain with
their respective rightsholders.

## Manual installation outline

1. Manually enable root Telnet on the SC2 and Sumo and confirm that recovery is
   possible before making persistent changes.
2. Copy the stock SC2 `/usr/bin/mppd`, SC2 `/usr/lib/libarsdk.so`, and Sumo
   `/usr/bin/dragon-prog` into persistent storage. Record and verify their
   hashes before continuing.
3. Transfer the matched files above through each device's FTP-visible storage.
4. Stop the affected service/process, remount the relevant root filesystem
   read-write, replace only the listed target, set executable mode `0755`, and
   verify its SHA-256 against this table before remounting read-only.
5. On the SC2, add the Sumo manually to `/etc/mppd/drone_manager.cfg` using the
   configuration syntax expected by that firmware. The required values are:
   product/model `2306` (`JS`), the unit's exact `JumpingSumo-…` SSID, open
   security, and no Wi-Fi key. Back up this configuration first.
6. Reboot one device at a time and confirm normal startup, Telnet access and
   process health before testing the pair.

The known-drone file format is firmware-specific, so this release deliberately
does not publish an unverified paste-and-run configuration block. The planned
installer will generate, validate and roll back the entry safely.

## RF/MOD note

The same RF/MOD mechanism used on the other Broadcom/SKY-based Parrot products
also operates on Jumping Sumo. Treat RF tuning as a separate experiment: first
prove stock-RF control and video, preserve the Sumo's original NVM values, and
use the existing RF Lab backup/restore workflow. Increased output can exceed
local limits and can worsen linearity, error rate or thermal load.

## Current scope

The patched SC2 profile recognizes and connects to product `0x0902`, translates
SC2 controls to native Jumping Sumo commands, maps jump actions, advertises
`JPEG/90000`, and forwards the Sumo's ARStream1 video for the Parrot Lab MJPEG
receiver. BB1/BB2 behavior is intended to remain unchanged, but this is still
an experimental binary patch rather than a supported Parrot configuration.
