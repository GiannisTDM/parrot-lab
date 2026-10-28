#!/usr/bin/env python3
"""Owner-authorized, staged SC3 data-property trial; never flashes an image.

Pinned spare only. snapshot is read-only; inspect attaches UBI (housekeeping
writes are possible) and mounts only data read-only; enable creates one absent
persist.debuggable file and cleanly unmounts/detaches. No automatic boot/reboot.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile
import uuid

import backup_nand as base

MOUNT = "/tmp/sc3-stock-data"
TARGET = MOUNT + "/property/persist.debuggable"
TEMP = MOUNT + "/property/.sc3-persist-debug-trial"
SIZE = 0x8020000
EXPECTED_SERIAL = "17d9849f"


def configure_transport(adb_argv, fastboot_serial):
    """Portable app adapter; historical CLI defaults remain pinned to the spare."""
    global EXPECTED_SERIAL
    if (not re.fullmatch(r"[A-Za-z0-9]{1,64}", fastboot_serial) or
            not adb_argv or not all(isinstance(x, str) and x for x in adb_argv)):
        raise ValueError("Invalid explicit transport/identity")
    base.GUARD = base.GUARD.replace("boxinit.serialno=" + EXPECTED_SERIAL + " ",
                                   "boxinit.serialno=" + fastboot_serial + " ")
    base.ADB = list(adb_argv)
    EXPECTED_SERIAL = fastboot_serial


def run(command, timeout=20):
    # Legacy ADB shell does not reliably propagate remote status. Require a
    # fresh final sentinel emitted only after the checked shell exits zero.
    marker = "SC3_OK_" + uuid.uuid4().hex
    wrapped = "/bin/sh -c " + shlex.quote("set -e\n" + command) + " && echo " + marker
    value = base.remote(wrapped, timeout=timeout)
    if not value.endswith(marker + "\n"):
        raise RuntimeError("Checked remote command failed: " + value[-700:])
    return value[:-(len(marker) + 1)]


def folder_ok(folder):
    folder = folder.resolve()
    if (folder.parent != Path("/Users/giannis/Downloads") or
            not re.fullmatch(r"sc3-persist-preflight\.[A-Za-z0-9]+", folder.name) or
            folder.stat().st_uid != os.getuid() or folder.stat().st_mode & 0o077):
        raise RuntimeError("Expected private preflight directory")
    return folder


def save(folder, name, value):
    base.put_text(folder / name, value)


def ram_guard():
    run('''[ "$(id -u)" = 0 ]
[ "$(cat /ramdiag/trace-profile)" = SC3-RAMDIAG-v3-trace ]
[ "$(cat /sys/kernel/config/usb_gadget/ramdiag/strings/0x409/serialnumber)" = SC3-RAMDIAG-181 ]
case " $(cat /proc/cmdline) " in *' root=/dev/ram0 '*) ;; *) exit 41;; esac
case " $(cat /proc/cmdline) " in *' boxinit.serialno=17d9849f '*) ;; *) exit 42;; esac
[ -e /tmp/keep-ramdiag ]
[ "$(cat /sys/class/mtd/mtd12/name)" = data ]
[ "$(cat /sys/class/mtd/mtd12/size)" = 134348800 ]
'''.replace("boxinit.serialno=17d9849f ", "boxinit.serialno=" + EXPECTED_SERIAL + " "))
    base.validate_mtd(run("cat /proc/mtd"))


def ecc():
    values = run("cat /sys/class/mtd/mtd12/ecc_failures /sys/class/mtd/mtd12/corrected_bits").split()
    if len(values) != 2 or not all(x.isdigit() for x in values):
        raise RuntimeError("Invalid sysfs ECC counters")
    return dict(failed=int(values[0]), corrected=int(values[1]))


def verify_snapshot(folder):
    manifest = json.loads((folder / "snapshot.json").read_text())
    if manifest["serial"] != EXPECTED_SERIAL or manifest["partition"] != "mtd12 data":
        raise RuntimeError("Wrong snapshot identity")
    if manifest["ecc_after"]["failed"] != 0:
        raise RuntimeError("Uncorrectable ECC in snapshot")
    rows = manifest["images"]
    if len(rows) != 2 or rows[0]["sha256"] != rows[1]["sha256"]:
        raise RuntimeError("Snapshot is not a matching pair")
    for row, name in zip(rows, ("data-before-a.bin", "data-before-b.bin")):
        path = folder / name
        if (row["file"] != name or path.is_symlink() or path.stat().st_size != SIZE or
                base.digest(path) != row["sha256"]):
            raise RuntimeError("Snapshot image changed")
    return manifest


def snapshot(folder):
    if any((folder / name).exists() for name in ("snapshot.json", "data-before-a.bin", "data-before-b.bin")):
        raise RuntimeError("Snapshot directory already used; no device command issued")
    base.guard()
    ram_guard()
    if shutil.disk_usage(folder).free < 512 * 1024**2:
        raise RuntimeError("Less than 512 MiB free")
    save(folder, "before-mounts.txt", run("cat /proc/mounts"))
    save(folder, "before-dmesg.txt", run("dmesg"))
    before = ecc()
    if before["failed"]:
        raise RuntimeError("Existing uncorrectable ECC counter")
    rows = []
    rdir = "/tmp/sc3-persist-snapshot-" + uuid.uuid4().hex[:12]
    run("umask 077; mkdir " + rdir)
    for label in ("a", "b"):
        base.guard()
        path = folder / ("data-before-" + label + ".bin")
        error = folder / ("data-before-" + label + ".adb-stderr.txt")
        log, status = rdir + "/" + label + ".stderr", rdir + "/" + label + ".status"
        command = (f"/bin/busybox nanddump --bb=padbad -s 0 -l {SIZE} -f - /dev/mtd12ro "
                   f"2>{log}; result=$?; printf '%s\\n' \"$result\" >{status}")
        print(base.now(), "data snapshot", label, "started", flush=True)
        with path.open("xb") as output, error.open("xb") as errors:
            child = subprocess.Popen(base.ADB + ["exec-out", command], stdout=output, stderr=errors)
            try:
                rc = base.wait_for_read(child, path, lambda n: print("bytes", n, flush=True),
                                        total_timeout=120, idle_timeout=20)
            except BaseException:
                child.kill(); child.wait(); raise
            output.flush(); os.fsync(output.fileno())
        remote_status, remote_log = run("cat " + status).strip(), run("cat " + log)
        save(folder, "data-before-" + label + ".nanddump-stderr.txt", remote_log)
        if rc or remote_status != "0" or remote_log or error.stat().st_size or path.stat().st_size != SIZE:
            raise RuntimeError("Data snapshot failed; no attach permitted")
        rows.append(dict(file=path.name, bytes=SIZE, sha256=base.digest(path)))
        print(base.now(), "data snapshot", label, "verified", flush=True)
    after = ecc()
    if rows[0]["sha256"] != rows[1]["sha256"] or after["failed"]:
        raise RuntimeError("Pair mismatch or uncorrectable ECC")
    base.put_json(folder / "snapshot.json", dict(
        time=base.now(), serial=EXPECTED_SERIAL, partition="mtd12 data", images=rows,
        ecc_before=before, ecc_after=after, oob=False, ecc_enabled=True,
        method="stock nanddump --bb=padbad; read-only MTD; no UBI attach"))
    print("FRESH_DATA_PAIR_VERIFIED", flush=True)


def mounted_guard(mode):
    ram_guard()
    text = run("cat /proc/mounts")
    rows = [line.split() for line in text.splitlines() if line.split()[2] == "ubifs"]
    if len(rows) != 1 or rows[0][:3] != ["ubi2:data", MOUNT, "ubifs"]:
        raise RuntimeError("Unexpected flash mount set")
    if mode not in rows[0][3].split(","):
        raise RuntimeError("Unexpected data mount mode")
    if set(run("ls /sys/class/ubi").split()) != {"ubi2", "ubi2_0", "ubi2_1", "version"}:
        raise RuntimeError("Unexpected UBI attachment set")
    run('''[ "$(cat /sys/class/ubi/ubi2/mtd_num)" = 12 ]
[ "$(cat /sys/class/ubi/ubi2_0/name)" = data ]
[ "$(cat /sys/class/ubi/ubi2_1/name)" = update ]
[ ! -L ''' + MOUNT + '''/property ]
[ "$(stat -c '%a:%u:%g' ''' + MOUNT + '''/property)" = 700:0:0 ]
''')


def binary_capture(folder, filename, command):
    # Only tar/stat-free binary data goes through exec-out; tar status saved
    # separately in RAM to avoid accepting a truncated archive as success.
    status = "/tmp/sc3-persist-capture-" + uuid.uuid4().hex
    path, err = folder / filename, folder / (filename + ".adb-stderr.txt")
    with path.open("xb") as out, err.open("xb") as errors:
        result = subprocess.run(base.ADB + ["exec-out", command +
            "; result=$?; printf '%s\\n' \"$result\" >" + status],
            stdout=out, stderr=errors, timeout=30)
        out.flush(); os.fsync(out.fileno())
    if result.returncode or err.stat().st_size or run("cat " + status).strip() != "0":
        raise RuntimeError("Binary capture failed")
    return base.digest(path)


def archive_files(path):
    """Compare property bytes/metadata without extracting private files."""
    result = {}
    with tarfile.open(path, "r:") as archive:
        for member in archive.getmembers():
            name = member.name.rstrip("/")
            if name == "property" and member.isdir():
                continue
            if (not member.isfile() or not re.fullmatch(r"property/persist\.[A-Za-z0-9_.-]+", name)
                    or name in result or member.size > 4096):
                raise RuntimeError("Unexpected property archive entry")
            value = archive.extractfile(member).read()
            result[name] = (member.uid, member.gid, member.mode, member.mtime, value)
    return result


def verify_only_target_changed(before, after):
    old, new = archive_files(before), archive_files(after)
    name = "property/persist.debuggable"
    if name in old or set(new) != set(old) | {name}:
        raise RuntimeError("Unexpected property file set change")
    if any(old[key] != new[key] for key in old):
        raise RuntimeError("Another persistent property's bytes or metadata changed")
    uid, gid, mode, _, value = new[name]
    if (uid, gid, mode, value) != (0, 0, 0o600, b"1"):
        raise RuntimeError("Unexpected debug property archive content")


def inspect(folder):
    if any((folder / name).exists() for name in ("attach.txt", "inspection.json", "enabled.json")):
        raise RuntimeError("Attachment phase already recorded; inspect state manually")
    verify_snapshot(folder)
    base.guard()
    ram_guard()
    run("[ ! -L " + MOUNT + " ]; umask 077; mkdir -p " + MOUNT)
    # First possible NAND housekeeping writes. No format, resize, erase,
    # volume creation, update-volume or MTD write command is used.
    # Stock BusyBox 1.25 advertises -O but its attach getopt omits it.
    # Default kernel VID offset is min-I/O 2048, matching saved EC headers.
    save(folder, "attach.txt", run("/bin/busybox ubiattach -d 2 -m 12 /dev/ubi_ctrl", 45))
    run('''[ "$(cat /sys/class/ubi/ubi2/mtd_num)" = 12 ]
[ "$(cat /sys/class/ubi/ubi2_0/name)" = data ]
[ "$(cat /sys/class/ubi/ubi2_1/name)" = update ]
mount -t ubifs -o ro,nosuid,nodev,noexec ubi2:data ''' + MOUNT, 30)
    inspect_mounted(folder)


def inspect_mounted(folder):
    if (folder / "inspection.json").exists() or (folder / "property-before.tar").exists():
        raise RuntimeError("Inspection already recorded; no device command issued")
    verify_snapshot(folder)
    mounted_guard("ro")
    save(folder, "inspection-dmesg.txt", run("dmesg"))
    save(folder, "inspection-mounts.txt", run("cat /proc/mounts"))
    metadata = run("stat -c '%n %a %u %g %s' " + MOUNT + "/property; ls -la " + MOUNT + "/property")
    save(folder, "property-before-metadata.txt", metadata)
    state = run("if [ -e " + TARGET + " ] || [ -L " + TARGET +
                " ]; then echo PRESENT; else echo ABSENT; fi").strip()
    archive_sha = binary_capture(folder, "property-before.tar", "/bin/busybox tar cf - -C " + MOUNT + " property")
    base.put_json(folder / "inspection.json", dict(time=base.now(), target=TARGET,
        state=state, property_archive_sha256=archive_sha, mounted_readonly=True,
        ubi_attach_may_have_written=True, ecc=ecc()))
    print("DATA_MOUNTED_READONLY; persist.debuggable=" + state, flush=True)


def enable(folder):
    if (folder / "enable-started.txt").exists() or (folder / "enabled.json").exists():
        raise RuntimeError("Enable phase already attempted; no device command issued")
    verify_snapshot(folder)
    inspection = json.loads((folder / "inspection.json").read_text())
    if inspection["state"] != "ABSENT" or inspection["target"] != TARGET:
        raise RuntimeError("Trial only creates a previously absent property")
    if base.digest(folder / "property-before.tar") != inspection["property_archive_sha256"]:
        raise RuntimeError("Rollback archive changed")
    mounted_guard("ro")
    if ecc()["failed"]:
        raise RuntimeError("Uncorrectable ECC before write")
    run("[ ! -e " + TARGET + " ]; [ ! -L " + TARGET + " ]; [ ! -e " + TEMP +
        " ]; [ ! -L " + TEMP + " ]")
    save(folder, "enable-started.txt", base.now() + "\nOwner-authorized single-property persistent change.\n")
    run("mount -o remount,rw,nosuid,nodev,noexec " + MOUNT, 30)
    mounted_guard("rw")
    # Match stock persistent writer's no-newline value and 0600 owner/mode.
    # Use an exclusive trial filename, never the property's shared .temp.
    run("umask 077; set -C; printf 1 >" + TEMP +
        "; chmod 0600 " + TEMP + "; /bin/busybox chown 0:0 " + TEMP +
        "; [ \"$(stat -c '%a:%u:%g:%s' " + TEMP + ")\" = 600:0:0:1 ]; "
        "[ ! -e " + TARGET + " ]; [ ! -L " + TARGET + " ]; /bin/busybox mv " + TEMP + " " + TARGET + "; /bin/busybox sync")
    result = run("[ ! -L " + TARGET + " ]; [ \"$(cat " + TARGET + ")\" = 1 ]; "
                 "stat -c '%a:%u:%g:%s' " + TARGET)
    if result.strip() != "600:0:0:1":
        raise RuntimeError("Written property metadata differs")
    save(folder, "property-after.txt", "value=1\nmode:uid:gid:size=" + result)
    run("mount -o remount,ro " + MOUNT, 30)
    mounted_guard("ro")
    binary_capture(folder, "property-after.tar", "/bin/busybox tar cf - -C " + MOUNT + " property")
    verify_only_target_changed(folder / "property-before.tar", folder / "property-after.tar")
    run("umount " + MOUNT, 30)
    run("/bin/busybox ubidetach -d 2 /dev/ubi_ctrl", 30)
    base.guard()
    save(folder, "after-unmount-dmesg.txt", run("dmesg"))
    base.put_json(folder / "enabled.json", dict(time=base.now(), value="1", property="persist.debuggable",
        filesystem="mtd12 / UBI data / property", uid=0, gid=0, mode="0600", bytes=1,
        data_unmounted=True, ubi_detached=True, ecc=ecc(),
        other_property_files_unchanged=True,
        rollback="After verifying original absent state: remove only /property/persist.debuggable from data in a fresh RAM session; sync and unmount."))
    print("ONE_PROPERTY_ENABLED; data unmounted; UBI detached; normal boot NOT yet requested", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("snapshot", "inspect", "inspect-mounted", "enable"))
    parser.add_argument("--folder", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    folder = folder_ok(args.folder)
    {"snapshot": snapshot, "inspect": inspect, "inspect-mounted": inspect_mounted, "enable": enable}[args.phase](folder)


if __name__ == "__main__":
    main()
