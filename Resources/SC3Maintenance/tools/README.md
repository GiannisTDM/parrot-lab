# Parrot Lab SC3 maintenance tools — API v1

Private, app-embeddable packaging of the **proven SC3 1.8.1 hardware-3** RAM-assisted
root enablement and **native Sumo v1c** startup modification. This is not an official
Parrot developer tool. It is not an ANAFI/SC2/SC4 workflow. No device is contacted
by building, importing, asking for help or verifying the assembled bundle.

## Files and scope

- `sc3_tool.py`: Mac-side Python 3.9+ standard-library CLI; JSON Lines stdout.
- `device/sumo-tool.sh`: SC3 BusyBox installer/unhooker, invoked only through host staging.
- `assets/`: exact proven V5 image, v1c executable, selector/control/init configuration.
- `legacy/`: preserved, guarded data-pair/UBIFS/property engine. Its old standalone
  NAND inventory CLI remains disabled; this adapter never reads/queries mibib.
- `manifest.json`: explicit resource inventory, sizes, SHA-256 and target SHA-1.

The bundle is self-contained; runtime does **not** require the repository, firmware
extraction, a cross compiler, or hardcoded `/Users/giannis` paths. The bundled
historical engine still contains its old CLI defaults; the adapter configures
transport/identity and invokes its guarded phase functions directly, never that CLI.
Python and adb/fastboot are **not** included. The app must ship/find a suitable
runtime and licensed platform-tools, then pass absolute executable paths. Do not
assume Finder-launched apps inherit Terminal's PATH or that macOS supplies Python.

Do not silently replace newer native-video/mapping work with this pinned v1c.
Unknown live binaries, startup hooks or init configurations are refused. A separate
versioned resource/installer contract is required for any v2; see its own worktree.

## Assemble offline, from the repository

```sh
python3 tools/package_sc3_app_tools.py --output build/sc3-app-tools-v1
python3 build/sc3-app-tools-v1/sc3_tool.py verify-bundle
```

The output directory must not already exist. Proven image/executable/script hashes
are pinned before copying. No source is rebuilt and no private device dump, pairing
key, factory/keystore partition or prior property archive is bundled. Firmware-derived
files are private integration resources; redistribution rights are not established.
Manifest hashes provide integrity, **not** publisher authenticity. Trust the signed
app's resources; do not accept arbitrary downloaded manifests/payloads.

## Mac API

All operations use argv arrays, not a shell. Common flags:

```text
--adb /absolute/platform-tools/adb
--fastboot /absolute/platform-tools/fastboot
--adb-port 5038
--endpoint 192.168.53.1:9050
--session /absolute/private/app-support/sc3-session-UNIQUE
```

No server kill/restart, unlock, erase, format, fastboot flash or firmware update
command is implemented. The tools never send a motor, PCMD or jump packet. Native
daemon startup can associate/control through physical inputs: require Sumo-off
before maintenance. Keep root ADB on trusted, isolated links; the persistent flag
also enables other stock debug consumers, not just ADB. No native USB ADB interface
is added: the demonstrated path is **TCP/9050 over USB RNDIS/ReRNDIS networking**.

Every mutating command requires `--confirm-write` from an explicit app confirmation.
Every Sumo mutation additionally requires `--sumo-off`. These switches are consent
tokens, not privilege/authentication mechanisms. They do not elevate the Mac.

### Root-enablement wizard (explicit phases)

Use one new private session directory; the tool creates it mode 0700. Retain it:
it holds sensitive data snapshots/property archives and rollback provenance.
Serials are detected automatically; there is no spare-controller allowlist. Keep
only the same controller connected throughout the workflow. Fastboot reports
**MPP2 even on this SC3**; this string alone is not sufficient identification.
Recorded identities still bind private evidence to its originating controller.
Legacy explicit serial flags are optional and remain supported for scripted use.

1. `prepare-root --session PATH` reads the normal HTTP properties API with proxies
   disabled, validates model and 1.8.1/hw3, records its reported stock identity,
   and creates the session. Any matching controller is accepted. No device state
   change. Initial HTTP identity is not a signature or cryptographic link to a
   later fastboot device. Physical evidence currently covers one controller.
2. Ask the user to enter fastboot manually. Observed entry: power off via holder,
   open holder and rapidly tap populated RTH six times around startup. RGB cycling
   accompanied success. This is recovered/owner-tested, not a documented Parrot
   guarantee; enumeration, not LED alone, establishes fastboot. Then call
   `wait-fastboot --session PATH`: it requires exactly one fastboot device and
   records its identity in an exclusive private receipt. No boot is sent. The
   next boot phase rechecks this session identity before sending its single boot.
3. `boot-root --session PATH --confirm-write`: checks only selected fastboot device,
   product/secure/download limit/battery gate, sends **one `fastboot boot`**, then
   bounded ADB reconnect/identity checks. Only after root/RAM/serial/no-flash checks
   does it create the RAM keep marker. V5 deliberately panics at ~90s without it
   and requests reboot after 30s. Failure is STOP, not an automatic boot retry.
   Ordinary stock boot may collect a panic report. This is not a production-grade
   recovery image or a guaranteed hardware watchdog.
4. `snapshot-root --session PATH --confirm-write`: two ECC-enabled main-area reads
   of data only, equal hash, exact size, no ECC failures. Requires ~512 MiB free.
   This is not a full NAND/OOB backup or a tested full-chip restore.
5. `inspect-root --session PATH --confirm-write`: attach mtd12 as UBI2, verify exact
   data/update volumes, mount only data read-only, privately archive its property
   directory. **UBI attachment may write housekeeping metadata.** No raw image restore.
6. `enable-root --session PATH --confirm-write`: requires prior absent property and
   valid matching snapshots/archive; writes one-byte `1` without newline, root:root
   0600, atomically to `property/persist.debuggable`. Journal recovery/UBIFS metadata
   writes can also occur. Compare every pre-existing property's bytes/metadata,
   return read-only, unmount and detach. Existing property values are not overwritten.
7. `return-stock --session PATH --confirm-write`: explicitly requests one reboot
   only after completed write and clean mount/UBI checks. A disconnect/timeout is an
   unknown acknowledgement, **not** permission to resend reboot.
8. After normal USB networking returns, `verify-root --session PATH` makes a fresh,
   proxy-free HTTP properties request to the selected controller. It checks the
   recorded identity/model/version and `rw.debuggable=1`; if `persist.debuggable`
   is exposed, that must also be `1`. Retail `ro.debuggable=0` is expected. This
   confirms web-reported debug enablement and does not use/reset/reconnect ADB
   or claim UID0, file metadata, original-adbd integrity or a changed boot ID.
   Retry only this read-only check while normal boot/networking becomes ready.

Optional `verify-root-adb --session PATH` retains the stronger shell check: UID0,
original adbd/read-only rootfs, no RAM marker, changed RAM/stock boot ID, stored
property metadata and both debug flags. The native manager/property removal still
require actual ADB root access; web verification alone does not establish it.

Every phase uses the same endpoint/server port as preparation. Arguments before
or after the operation are accepted. Session locks prevent overlapping root phases;
started artifacts prevent replay after ambiguous failures. Don't delete a lock or
marker automatically: inspect process and mount/UBI state first. A stuck kernel NAND
read cannot be fixed by terminating the host child. The package does not automate
recovery from interrupted attachment/write phases.

An already-rooted controller needs only:

```sh
python3 sc3_tool.py verify-root
```

Rollback: `disable-root --session PATH --confirm-write` removes **only** the same
verified one-byte property when this session recorded its original absence. It
does not reboot/stop the running adbd. Restore/disable the Sumo mod first if desired;
a later normal reboot re-evaluates original debug gates. No claim that this alone
guarantees ADB off if another stock debug gate applies. Old installations without
this package's provenance are not force-removed; use the original guarded manual
rollback procedure. Root persistence is ordinary-boot, not reset/update-proof.

### Native Sumo modification

Root ADB must already work. These commands detect stock identity and enforce
model/version/hash guards; use no root session argument. For example:

```sh
python3 sc3_tool.py sumo-status python3 sc3_tool.py sumo-install --confirm-write --sumo-off
```

| Operation | Effect |
|---|---|
| `sumo-status` | Read service, executable variant/hash and startup flag; no upload |
| `sumo-install` | Copy/hash/rename stock binary and init backups if absent; stage v1c; install persistent selector/init hook; enable future startup; **no daemon restart/reboot** |
| `sumo-enable` | Enable future native startup, no restart |
| `sumo-disable` | Disable future selection, current session unchanged |
| `sumo-activate` | Apply current-boot overlay/restart via existing supervisor; may associate normally; no drive/jump packet injected |
| `sumo-stock` | Disable startup; restore stock and restart if an overlay is active; an already-stock stopped service is not forcibly started |
| `sumo-remove-hook` | Restore stock now and original init file; retain backups and unused selector for cached init until next normal reboot |

The rootfs is writable only during installation/unhook, then synced/remounted
read-only. Underlying `/usr/bin/mppd` is never replaced. Native binary stays under
`/data/lib/mppd/native-sumo/`; backups stay under `native-sumo-backup/`. Rootfs hook
addition is a real persistent rootfs change. Selector defaults to stock without
the marker or on known validation failures, and falls back after three previous
native launch attempts in the same boot (not a general crash/motor failsafe).

Installed init definitions are cached until reboot. `sumo-install` plus explicit
`sumo-activate` can apply the overlay now; full fresh-init validation requires a
separately user-authorized normal reboot and read-only status check. The CLI does
not reboot during Sumo installation. No learned-drone list/key is modified; the
app must separately use its verified pairing workflow. v1c selects remembered
open Sumo model 2306/0x0902. It does not implement video or isolated mapping UI.

Staging files remain under a unique `sc3-app-stage-*` directory for inspection;
no recursive cleanup is performed. On success the app may later remove only its
verified staged file list and that empty directory. Do not wipe `/data/lib/mppd`.

## Output, errors and validation boundary

Stdout contains one JSON object per line: `api:1`, `event`, plus phase-specific
fields. Events: `started`, `prepared`, `progress`, `ram_ready`, `phase_complete`,
`reboot_requested`, `reboot_ack_unknown`, `debug_verified` (HTTP),
`root_verified` (optional ADB), `root_disabled`,
`sumo_status`, `sumo_complete`, `bundle_verified`, `completed`, `error`.
`sumo_complete` separately reports `automatic_startup` (null when not changed),
`daemon_restart_possible`, `reboot_requested` and `movement_packets_sent`.
Exit 0 means the requested operation completed; exit 1 is STOP with an error event;
argparse misuse exits 2. `sumo_complete` install is **not** a connected robot/video
claim. Report phase rather than a fabricated overall percentage. Snapshot progress
and evidence are saved privately; don't publish/upload those logs by default.

This packaging has host fixture tests and offline artifact checks. The **underlying
V5/property mechanism and v1c/autostart** were physically demonstrated earlier;
the new wizard/installer are not automatically classified as end-to-end bench-tested.
No root enablement, mod reinstall, reboot or motor command should be performed
merely to package or integrate the UI. Request the next appropriate bench checkpoint.
