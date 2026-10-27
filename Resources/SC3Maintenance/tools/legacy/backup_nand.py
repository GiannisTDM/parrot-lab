#!/usr/bin/env python3
"""Historical two-read NAND backup experiment; live CLI disabled after mibib stall.

No flash mount/attach/write, reset, update, credential or persistent-property
operation exists here. Generated files are private local preservation artifacts.
Helper, logs and status markers on the controller live exclusively in /tmp.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from zoneinfo import ZoneInfo

REPO = Path(__file__).resolve().parents[2]
ADB = ["adb", "-P", "5038", "-s", "192.168.53.1:9050"]
PARTS = list(enumerate(zip(
    ["sbl", "mibib", "tz", "rpm", "devinfo", "keystore", "misc", "aboot",
     "boot", "recovery", "factory", "system", "data"],
    [0x140000, 0x140000, 0x120000, 0xc0000, 0x160000, 0xe0000, 0x140000,
     0xc0000, 0x1920000, 0xf20000, 0x1000000, 0x3f00000, 0x8020000])))
# Preserve paired copies of the previously readable main partitions first.
# Boot-ROM-reserved regions are last; v1 stalled in a lazy mibib ECC query.
READ_ORDER = (8, 9, 10, 11, 12, 7, 4, 5, 6, 2, 3, 0, 1)
GUARD = r'''set -e
[ "$(id -u)" = 0 ]
[ "$(cat /ramdiag/trace-profile)" = SC3-RAMDIAG-v3-trace ]
[ "$(cat /sys/kernel/config/usb_gadget/ramdiag/strings/0x409/serialnumber)" = SC3-RAMDIAG-181 ]
case " $(cat /proc/cmdline) " in *' root=/dev/ram0 '*) ;; *) exit 41;; esac
case " $(cat /proc/cmdline) " in *' boxinit.serialno=17d9849f '*) ;; *) exit 42;; esac
if grep -q 'ubifs\|/dev/mtd\|/dev/mmcblk' /proc/mounts; then exit 43; fi
grep -q '^tmpfs /tmp tmpfs ' /proc/mounts
[ "$(ls /sys/class/ubi)" = version ]
[ -e /tmp/keep-ramdiag ]
echo SC3_BACKUP_GUARD_OK
'''


def now():
    return datetime.datetime.now(ZoneInfo("Europe/Athens")).isoformat(timespec="seconds")


def digest(path, algorithm="sha256"):
    h = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def remote(command, timeout=15):
    r = subprocess.run(ADB + ["shell", command], capture_output=True, timeout=timeout)
    if r.returncode or r.stderr:
        raise RuntimeError("ADB text command failed: " + repr(r.stderr[:400]))
    return r.stdout.decode("utf-8", errors="strict").replace("\r\n", "\n")


def guard():
    if remote(GUARD).strip() != "SC3_BACKUP_GUARD_OK":
        raise RuntimeError("RAM/root/identity/no-flash guard did not pass")


def validate_mtd(text):
    rows = []
    for line in text.splitlines():
        m = re.fullmatch(r'mtd(\d+):\s+([0-9a-f]+)\s+([0-9a-f]+)\s+"([^"\n]+)"', line)
        if m:
            rows.append((int(m[1]), m[4], int(m[2], 16), int(m[3], 16)))
    expected = [(n, name, size, 131072) for n, (name, size) in PARTS]
    if rows != expected:
        raise RuntimeError("MTD map differs from the pinned spare map")
    return rows


def put_text(path, text):
    with path.open("x", encoding="utf-8") as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())


def put_json(path, value):
    put_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def validate_map(value):
    if value.get("format") != "sc3-readonly-mtd-map-v2" or value.get("ecc_stats_ioctl_used") is not False:
        raise RuntimeError("Unexpected bad-block helper format")
    parts = value.get("partitions", [])
    if len(parts) != len(PARTS):
        raise RuntimeError("Incomplete bad-block map")
    for p, (n, (_, size)) in zip(parts, PARTS):
        if (p["mtd"], p["size"], p["erasesize"], p["writesize"], p["oobsize"],
                p["queried_blocks"]) != (n, size, 131072, 2048, 64, size // 131072):
            raise RuntimeError("Bad-block helper geometry mismatch")
        offsets = p["bad_offsets"]
        if offsets != sorted(set(offsets)) or any(x < 0 or x >= size or x % 131072 for x in offsets):
            raise RuntimeError("Invalid bad-block offsets")
    return value


def compare_maps(before, after):
    for a, b in zip(before["partitions"], after["partitions"]):
        if a["bad_offsets"] != b["bad_offsets"]:
            raise RuntimeError("Bad-block map changed during backup")


def wait_for_read(child, path, progress, total_timeout=600, idle_timeout=20):
    started = last_change = last_report = time.monotonic()
    previous = 0
    while child.poll() is None:
        current = path.stat().st_size
        clock = time.monotonic()
        if current != previous:
            last_change = clock
            previous = current
        if clock - last_report >= 15:
            progress(current)
            last_report = clock
        if clock - last_change > idle_timeout or clock - started > total_timeout:
            raise RuntimeError("NAND read made no progress or exceeded its deadline; no retry")
        time.sleep(0.5)
    return child.returncode


def metadata(folder, label):
    guard()
    for filename, command in {
        "proc-mtd.txt": "cat /proc/mtd",
        "cmdline.txt": "cat /proc/cmdline",
        "mounts.txt": "cat /proc/mounts",
        "kernel-log.txt": "dmesg",
        "identity.txt": "id; uname -a; cat /ramdiag/identity.txt /ramdiag/trace-profile; cat /proc/uptime",
        "sysfs-mtd.txt": '''for n in /sys/class/mtd/mtd[0-9]*; do case "$n" in *ro) continue;; esac; echo "$n"; for f in name type size erasesize writesize oobsize offset bad_blocks bbt_blocks corrected_bits ecc_failures ecc_strength ecc_step_size bitflip_threshold; do if [ -r "$n/$f" ]; then echo "$f=$(cat "$n/$f")"; fi; done; done''',
    }.items():
        put_text(folder / (label + "-" + filename), remote(command))


def backup(helper):
    os.umask(0o077)
    guard()
    mtd = remote("cat /proc/mtd")
    validate_mtd(mtd)
    parent = Path("/Users/giannis/Downloads")
    if shutil.disk_usage(parent).free < 1024 ** 3:
        raise RuntimeError("Less than 1 GiB free for private backup")
    folder = Path(tempfile.mkdtemp(prefix="sc3-181-PI040443CA0A194914-private-", dir=parent))
    print(now(), "Private backup directory:", folder, flush=True)
    journal = (folder / "journal.ndjson").open("x", encoding="utf-8")
    def record(event):
        event = {"time": now(), **event}
        journal.write(json.dumps(event, sort_keys=True) + "\n")
        journal.flush()
        os.fsync(journal.fileno())
        print(event["time"], event.get("event"), event.get("partition", ""), flush=True)
    try:
        metadata(folder, "before")
        put_text(folder / "nanddump-help.txt", remote("/bin/busybox nanddump --help 2>&1"))
        rdir = "/tmp/sc3-nand-backup-" + folder.name.rsplit("-", 1)[-1]
        if not re.fullmatch(r"/tmp/sc3-nand-backup-[a-z0-9_]+", rdir):
            raise RuntimeError("Unexpected temporary directory name")
        if remote("umask 077; mkdir " + shlex.quote(rdir) + " && echo TMP_READY").strip() != "TMP_READY":
            raise RuntimeError("Could not create private RAM workspace")
        target = rdir + "/mtd-readonly-map"
        guard()
        subprocess.run(ADB + ["push", str(helper), target], check=True, capture_output=True, timeout=15)
        if remote("chmod 0700 " + target + " && /bin/busybox md5sum " + target).split()[0] != digest(helper, "md5"):
            raise RuntimeError("Uploaded helper hash mismatch")
        put_json(folder / "tool-provenance.json", {
            "helper_sha256": digest(helper),
            "helper_source_sha256": digest(REPO / "tools/sc3_ramdiag/mtd_readonly_map.c"),
            "backup_script_sha256": digest(Path(__file__)),
            "image_sha256": "1af51a48d6523902baf589574b6e56daba3134dd48a7514558c9a6253511c3a0",
            "remote_helper": target,
        })
        def scan(label):
            guard()
            text = remote(target, timeout=120)
            put_text(folder / (label + "-badblocks.json"), text)
            return validate_map(json.loads(text))
        # Never call the helper's old ECC stats query. Copy main areas before
        # an optional inventory scan so a scan failure cannot discard good pairs.
        results = {"pass-a": [], "pass-b": []}
        for pass_name in ("pass-a", "pass-b"):
            (folder / pass_name).mkdir(mode=0o700)
        for n in READ_ORDER:
            name, size = PARTS[n][1]
            for pass_name in ("pass-a", "pass-b"):
                outdir = folder / pass_name
                guard()
                stem = f"mtd{n:02d}-{name}"
                partial = outdir / (stem + ".bin.partial")
                final = outdir / (stem + ".bin")
                log = f"{rdir}/{pass_name}-{n}.stderr"
                status = f"{rdir}/{pass_name}-{n}.status"
                command = (f"/bin/busybox nanddump --bb=padbad -s 0 -l {size} -f - /dev/mtd{n}ro "
                           f"2>{log}; result=$?; printf '%s\\n' \"$result\" >{status}")
                record({"event": "read-start", "partition": name, "pass": pass_name, "expected_bytes": size})
                client_log = outdir / (stem + ".adb-stderr.txt")
                with partial.open("xb") as output, client_log.open("xb") as error:
                    child = subprocess.Popen(ADB + ["exec-out", command], stdout=output, stderr=error)
                    try:
                        rc = wait_for_read(child, partial, lambda amount: record({
                            "event": "read-progress", "partition": name, "pass": pass_name, "bytes": amount}))
                    except BaseException:
                        child.kill(); child.wait(); raise
                    output.flush(); os.fsync(output.fileno())
                remote_rc = remote("cat " + status).strip()
                remote_log = remote("cat " + log)
                put_text(outdir / (stem + ".nanddump-stderr.txt"), remote_log)
                put_text(outdir / (stem + ".remote-status.txt"), remote_rc + "\n")
                actual = partial.stat().st_size
                if rc != 0 or remote_rc != "0" or remote_log or client_log.stat().st_size or actual != size:
                    raise RuntimeError(f"Read validation failed: {pass_name}/{stem}; host={rc} remote={remote_rc} bytes={actual}/{size}; see private logs")
                sha = digest(partial)
                if pass_name == "pass-b" and sha != next(r["sha256"] for r in results["pass-a"] if r["mtd"] == n):
                    raise RuntimeError("Independent read hash mismatch: " + name)
                partial.rename(final)
                row = {"mtd": n, "name": name, "bytes": actual, "sha256": sha, "file": str(final.relative_to(folder)),
                       "remote_exit_status": 0, "host_exit_status": rc}
                results[pass_name].append(row)
                record({"event": "read-verified", "partition": name, "pass": pass_name, "bytes": actual, "sha256": sha})
            record({"event": "partition-pair-complete", "partition": name})
        baseline = scan("after-images")
        record({"event": "bad-block-map-complete", "queried_blocks": sum(p["queried_blocks"] for p in baseline["partitions"]),
                "bad_blocks": sum(len(p["bad_offsets"]) for p in baseline["partitions"])})
        for rows in results.values():
            rows.sort(key=lambda row: row["mtd"])
        metadata(folder, "after")
        manifest = {"format": "sc3-ecc-on-padbad-backup-v1", "completed": now(), "serial": "PI040443CA0A194914",
                    "fastboot_serial": "17d9849f", "source_firmware": "1.8.1", "read_only_nodes": True,
                    "ecc": "enabled (no -n)", "bad_block_policy": "padbad: substitute marked bad blocks with FF",
                    "oob_included": False, "two_independent_reads_match": True,
                    "bytes_per_pass": 268435456, "passes": results,
                    "restoration_tested": False, "sensitive_private_backup": True}
        put_json(folder / "manifest.json", manifest)
        hashes = []
        for path in sorted(folder.rglob("*")):
            if path.is_file() and path.name != "journal.ndjson":
                hashes.append(digest(path) + "  " + str(path.relative_to(folder)))
        put_text(folder / "checksums.sha256", "\n".join(hashes) + "\n")
        record({"event": "backup-complete", "matching_partitions": 13, "total_image_bytes": 536870912})
        print("BACKUP_COMPLETE", folder, flush=True)
    except BaseException as exc:
        put_text(folder / "FAILED.txt", now() + "\n" + str(exc) + "\nPartial evidence retained; not a verified complete backup.\n")
        print("BACKUP_FAILED", folder, type(exc).__name__, str(exc), flush=True)
        raise
    finally:
        journal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--backup", action="store_true")
    args = parser.parse_args()
    helper = args.helper.resolve()
    if not helper.is_file():
        parser.error("missing compiled read-only helper")
    if not args.backup:
        print("No backup requested; no device commands executed.")
        return
    parser.error("Live execution disabled: mibib bad-block queries reproducibly stall the stock NAND driver. "
                 "No device commands executed. See notes/sc3-nand-backup-result-2026-10-26.md; "
                 "executed source and partial backups are preserved privately.")


if __name__ == "__main__":
    main()
