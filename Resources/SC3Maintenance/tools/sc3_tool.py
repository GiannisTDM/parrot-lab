#!/usr/bin/env python3
"""Parrot Lab SC3 maintenance API v1. JSON Lines stdout; no interactive prompts.

Use the assembled bundle, not this source directory. Mutations are explicit,
phase-separated, identity-bound and never automatically retried.
"""
from __future__ import annotations
import argparse
import contextlib
import hashlib
import importlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import time
import urllib.request
import uuid

# Do not create __pycache__ inside a signed app's sealed resource directory.
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
STOCK = "52398949fe32b46b0251b2c7f63942593c068d62"
PATCH = "83874fd41722c8391b3e530c7fce0e2ff3bab461"
RAM_SHA = "1af51a48d6523902baf589574b6e56daba3134dd48a7514558c9a6253511c3a0"
PATCH_SHA = "f561113254ea50465eca823b6b1ebb8d3acefddb9f0920043fc960c4218a5c96"
STOCK_INIT = "bcd89c78ce123680b3c40f3dbbaf61fffb54b0fc"
SCRIPT_PINS = {
    "assets/startup.sh": "0be1f74b8829fb66d07a8401fd7330b4a5016d87",
    "assets/control.sh": "1b22641d969a0a2fef45d72d1f51bd4ab5c66b99",
    "assets/99-mppd.native.rc": "5e6af16f7bddfdf0c604c364a3e6d129497ff07f",
}


def emit(event, **fields):
    print(json.dumps(dict(api=1, event=event, **fields), sort_keys=True), flush=True)


def digest(path, kind="sha256"):
    h = hashlib.new(kind)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_new(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def verify_bundle(root):
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest.get("format") != "parrot-lab-sc3-tools-v1" or manifest.get("api") != 1:
        raise ValueError("Unsupported resource manifest")
    required = {"sc3_tool.py", "README.md", "device/sumo-tool.sh", "assets/startup.sh",
                "assets/control.sh", "assets/99-mppd.native.rc", "assets/sc3-ramdiag-v5.img",
                "assets/mppd.native-sumo-v1c", "legacy/backup_nand.py",
                "legacy/persistent_debug_trial.py"}
    if set(manifest["files"]) != required:
        raise ValueError("Resource file set differs from API v1")
    for name, row in manifest["files"].items():
        path = root / name
        if (PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts or
                any(p.is_symlink() for p in [path, *path.parents[:len(PurePosixPath(name).parts)-1]]) or
                not path.is_file() or path.stat().st_size != row["bytes"] or
                digest(path) != row["sha256"] or digest(path, "sha1") != row["sha1"]):
            raise ValueError("Resource integrity check failed: " + name)
    if (manifest["files"]["assets/sc3-ramdiag-v5.img"]["sha256"] != RAM_SHA or
            manifest["files"]["assets/mppd.native-sumo-v1c"]["sha256"] != PATCH_SHA):
        raise ValueError("Not the proven V5/v1c payloads")
    if any(manifest["files"][name]["sha1"] != expected for name, expected in SCRIPT_PINS.items()):
        raise ValueError("Not the pinned v1c startup scripts")
    return manifest


def serial(value):
    if not re.fullmatch(r"[A-Za-z0-9]{1,64}", value):
        raise ValueError("Expected an explicit alphanumeric device serial")
    return value


def endpoint(value):
    host, port = value.split(":")
    if ipaddress.ip_address(host).version != 4 or not 1 <= int(port) <= 65535:
        raise ValueError("Expected an IPv4:port ADB endpoint")
    return value


def property_values(rows):
    if (not isinstance(rows, list) or len(rows) > 64 or
            any(not isinstance(row, dict) or not isinstance(row.get("key"), str) or
                not isinstance(row.get("value"), str) for row in rows)):
        raise ValueError("Malformed controller properties")
    props = {row["key"]: row["value"] for row in rows}
    if len(props) != len(rows):
        raise ValueError("Duplicate controller property keys")
    return props


def parse_properties(rows, expected_serial=None):
    props = property_values(rows)
    if tuple(props.get(k) for k in ("ro.product.model", "ro.parrot.build.version", "ro.revision")) != (
            "Skycontroller 3", "1.8.1", "3"):
        raise ValueError("Only SC3 retail 1.8.1 hardware 3 is supported")
    actual = serial(props.get("ro.factory.serial", ""))
    if expected_serial and actual != expected_serial:
        raise ValueError("Stock serial does not match selected controller")
    return dict(stock_serial=actual, firmware="1.8.1", hardware="3", model="Skycontroller 3")


class Tool:
    def __init__(self, args):
        self.args = args
        self.manifest = verify_bundle(HERE)
        self.adb = [args.adb, "-P", str(args.adb_port), "-s", endpoint(args.endpoint)]
        self.state = None
        self.folder = args.session

    def process(self, argv, timeout=15):
        value = subprocess.run(argv, capture_output=True, timeout=timeout)
        if value.returncode:
            raise RuntimeError("Child process failed; no automatic retry: " +
                               (value.stderr + value.stdout).decode(errors="replace")[-500:])
        return value.stdout.decode(errors="strict").replace("\r\n", "\n"), value.stderr.decode(errors="replace")

    def shell(self, code, timeout=15):
        # Legacy ADB shell can exit zero on a failed remote command.
        token = "SC3_OK_" + uuid.uuid4().hex
        command = "/bin/sh -c " + shlex.quote("set -e\n" + code) + " && echo " + token
        out, err = self.process(self.adb + ["shell", command], timeout)
        if err or not out.endswith(token + "\n"):
            raise RuntimeError("Remote checked command failed; no automatic retry: " + out[-300:])
        return out[:-(len(token) + 1)]

    def stock_guard(self):
        expected = self.state["stock_serial"] if self.state else self.args.stock_serial
        code = '''[ "$(id -u)" = 0 ]
[ ! -e /ramdiag/trace-profile ]
[ "$(gprop ro.product.model)" = 'Skycontroller 3' ]
[ "$(gprop ro.parrot.build.version)" = 1.8.1 ]
[ "$(gprop ro.revision)" = 3 ]
grep -q '^ubi0:rootfs / ubifs ro,' /proc/mounts
[ "$(sha1sum /usr/bin/adbd | cut -d ' ' -f 1)" = e6800e8eac830f67a313f9cc49f91d375f49bbc0 ]
gprop ro.factory.serial
'''
        actual = serial(self.shell(code).strip())
        if expected and actual != expected:
            raise ValueError("Connected controller differs from the recorded session")
        self.args.stock_serial = actual
        return actual

    def http_properties(self):
        host = endpoint(self.args.endpoint).split(":")[0]
        # Fresh requests to the selected controller; never use a proxy/cache.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        request = urllib.request.Request("http://" + host + "/api/v1/info/properties",
            headers={"Cache-Control": "no-cache, no-store", "Pragma": "no-cache"})
        with opener.open(request, timeout=5) as response:
            data = response.read(16385)
        if len(data) > 16384:
            raise ValueError("Oversized properties response")
        rows = json.loads(data)
        property_values(rows)
        return rows

    def prepare(self):
        if not self.folder or self.folder.exists():
            raise ValueError("--session must name a NEW private directory")
        fast = serial(self.args.fastboot_serial) if self.args.fastboot_serial else None
        info = parse_properties(self.http_properties(), self.args.stock_serial)
        self.folder.mkdir(mode=0o700)
        self.state = dict(format="sc3-app-session-v1", **info, fastboot_serial=fast,
                          endpoint=self.args.endpoint, adb_port=self.args.adb_port,
                          ram_sha256=RAM_SHA, stock_boot_verified=False)
        write_new(self.folder / "session.json", self.state)
        emit("prepared", session=str(self.folder), **info,
             next="Manually enter fastboot; boot-root sends one RAM boot only.")

    @contextlib.contextmanager
    def session(self):
        folder = self.folder
        if (not folder or folder.is_symlink() or not folder.is_dir() or
                folder.stat().st_uid != os.getuid() or folder.stat().st_mode & 0o077):
            raise ValueError("Expected an existing private, owned session directory (0700)")
        self.state = json.loads((folder / "session.json").read_text())
        if (self.state.get("format") != "sc3-app-session-v1" or
                self.state["endpoint"] != self.args.endpoint or self.state["adb_port"] != self.args.adb_port or
                self.state["ram_sha256"] != RAM_SHA):
            raise ValueError("Session transport or image identity differs")
        serial(self.state["stock_serial"])
        if self.state.get("fastboot_serial"):
            serial(self.state["fastboot_serial"])
        selected = folder / "fastboot-selected.json"
        if selected.exists():
            if selected.is_symlink(): raise ValueError("Invalid fastboot selection receipt")
            receipt = json.loads(selected.read_text())
            detected = serial(receipt["serial"])
            if (receipt["stock_serial"] != self.state["stock_serial"] or
                    self.state.get("fastboot_serial") not in (None, detected)):
                raise ValueError("Fastboot receipt differs from saved session")
            self.state["fastboot_serial"] = detected
        if ((self.args.stock_serial and self.args.stock_serial != self.state["stock_serial"]) or
                (self.args.fastboot_serial and self.args.fastboot_serial != self.state["fastboot_serial"])):
            raise ValueError("Explicit serial differs from saved session identity")
        lock = folder / ".operation-lock"
        with lock.open("x") as out:
            out.write(str(os.getpid()))
        try:
            yield
        finally:
            lock.unlink()

    def select_fastboot(self):
        out, _ = self.process([self.args.fastboot, "devices"], 5)
        rows = [line.split() for line in out.splitlines() if line.strip()]
        if len(rows) != 1 or len(rows[0]) != 2 or rows[0][1] != "fastboot":
            raise ValueError("Connect exactly one controller in fastboot; no device is selected from an ambiguous list")
        detected = serial(rows[0][0])
        expected = self.state.get("fastboot_serial") or self.args.fastboot_serial
        if expected and detected != expected:
            raise ValueError("Fastboot controller changed during this session")
        if not self.state.get("fastboot_serial"):
            write_new(self.folder / "fastboot-selected.json", dict(serial=detected, stock_serial=self.state["stock_serial"]))
        self.state["fastboot_serial"] = detected
        emit("fastboot_ready", serial=detected)

    def boot(self):
        serial_ = serial(self.state.get("fastboot_serial") or "")
        marker = self.folder / "boot-started.json"
        if marker.exists():
            raise ValueError("RAM boot already attempted; do not automatically replay")
        out, _ = self.process([self.args.fastboot, "devices"], 5)
        rows = [line.split()[0] for line in out.splitlines() if line.split() and "fastboot" in line]
        if rows != [serial_]:
            raise ValueError("Expected only the selected fastboot controller")
        prefix = [self.args.fastboot, "-s", serial_]
        values = {}
        for key in ("product", "secure", "max-download-size", "battery-soc-ok"):
            out, err = self.process(prefix + ["getvar", key], 5)
            match = re.search(r"^(?:\(bootloader\)\s*)?" + re.escape(key) + r":\s*(\S+)", out + err, re.M)
            if not match:
                raise ValueError("Missing fastboot variable: " + key)
            values[key] = match[1]
        if (values["product"] != "MPP2" or values["secure"] != "no" or
                values["battery-soc-ok"] != "yes" or
                int(values["max-download-size"], 0) <= (HERE / "assets/sc3-ramdiag-v5.img").stat().st_size):
            raise ValueError("Fastboot preconditions differ from the proven controller")
        write_new(marker, dict(serial=serial_, variables=values, attempted=True))
        emit("progress", phase="boot-root", detail="Sending ONE temporary RAM boot; no flash/unlock command")
        self.process(prefix + ["boot", str(HERE / "assets/sc3-ramdiag-v5.img")], 30)
        # V5 has an intentional 90s panic timer; promptly cancel only after identity checks.
        deadline = time.monotonic() + 50
        while time.monotonic() < deadline:
            try:
                self.process([self.args.adb, "-P", str(self.args.adb_port), "connect", self.args.endpoint], 3)
                code = r'''[ "$(id -u)" = 0 ]
[ "$(cat /ramdiag/trace-profile)" = SC3-RAMDIAG-v3-trace ]
[ "$(cat /sys/kernel/config/usb_gadget/ramdiag/strings/0x409/serialnumber)" = SC3-RAMDIAG-181 ]
case " $(cat /proc/cmdline) " in *' root=/dev/ram0 '*) ;; *) exit 41;; esac
case " $(cat /proc/cmdline) " in *' boxinit.serialno=SERIAL '*) ;; *) exit 42;; esac
! grep -q 'ubifs\|/dev/mtd\|/dev/mmcblk' /proc/mounts
[ "$(ls /sys/class/ubi)" = version ]
touch /tmp/keep-ramdiag
cat /proc/sys/kernel/random/boot_id
'''.replace("SERIAL", serial_)
                boot_id = self.shell(code, 5).strip()
                if not re.fullmatch(r"[a-f0-9-]{36}", boot_id):
                    raise RuntimeError("Missing RAM boot ID")
                write_new(self.folder / "ram-ready.json", dict(boot_id=boot_id, keep_marker=True))
                emit("ram_ready", boot_id=boot_id, next="snapshot-root; persistent data not yet attached")
                return
            except (RuntimeError, subprocess.TimeoutExpired):
                time.sleep(1)
        raise RuntimeError("RAM ADB not verified in time. V5 may intentionally panic/return to stock. No retry sent.")

    def ram_guard(self):
        ready = json.loads((self.folder / "ram-ready.json").read_text())
        boot_id = self.shell("cat /proc/sys/kernel/random/boot_id").strip()
        if boot_id != ready["boot_id"]:
            raise ValueError("This is not the recorded RAM session")
        trial = self.trial_engine()
        trial.ram_guard()
        return trial

    def trial_engine(self):
        sys.path.insert(0, str(HERE / "legacy"))
        trial = importlib.import_module("persistent_debug_trial")
        trial.configure_transport(self.adb, self.state["fastboot_serial"])
        return trial

    def root_phase(self, phase):
        trial = self.ram_guard()
        function = {"snapshot-root": trial.snapshot, "inspect-root": trial.inspect,
                    "enable-root": trial.enable}[phase]
        log = self.folder / (phase + ".log")
        if log.exists():
            raise ValueError("Phase was already attempted; inspect private evidence, do not replay")
        emit("progress", phase=phase, detail={
            "snapshot-root": "Two ECC-enabled data reads; no mibib query or UBI attachment",
            "inspect-root": "Attach only mtd12; UBI housekeeping writes may occur; mount data read-only",
            "enable-root": "Atomically create only absent persist.debuggable=1; verify, unmount and detach",
        }[phase])
        with log.open("x") as output, contextlib.redirect_stdout(output):
            function(self.folder)
        emit("phase_complete", phase=phase, private_log=str(log))

    def return_stock(self):
        self.ram_guard()
        if not (self.folder / "enabled.json").is_file():
            raise ValueError("No completed enable phase")
        self.shell("! grep -q ubifs /proc/mounts; [ \"$(ls /sys/class/ubi)\" = version ]")
        write_new(self.folder / "return-stock-started.json", dict(requested=True))
        # ADB may disconnect before it reports success. Never automatically retry.
        try:
            self.process(self.adb + ["reboot"], 5)
        except (RuntimeError, subprocess.TimeoutExpired):
            emit("reboot_ack_unknown", next="Wait for normal USB networking, then verify-root. Do not resend reboot.")
            return
        emit("reboot_requested", next="Wait for stock USB networking, then verify-root")

    def verify_root(self):
        rows = self.http_properties()
        expected = self.state["stock_serial"] if self.state else self.args.stock_serial
        info = parse_properties(rows, expected)
        props = property_values(rows)
        current, persistent = props.get("rw.debuggable"), props.get("persist.debuggable")
        # Retail ro.debuggable remains 0. The runtime flag is the web-visible
        # enablement result; this is deliberately not a claim of shell UID0.
        if current != "1" or persistent not in (None, "1"):
            raise ValueError("Web API has not confirmed debug enablement: rw.debuggable=" + str(current) +
                             ", persist.debuggable=" + str(persistent) + ". Wait for normal boot and repeat only this read-only check.")
        receipt = dict(**info, rw_debuggable=current, persist_debuggable=persistent,
                       transport="HTTP properties", adb_verified=False, checked_at=time.time())
        if self.state:
            write_new(self.folder / ("web-debug-verified-" + uuid.uuid4().hex + ".json"), receipt)
        emit("debug_verified", **receipt)

    def verify_root_adb(self):
        actual = self.stock_guard()
        out = self.shell('''[ "$(gprop rw.debuggable)" = 1 ]
[ "$(gprop persist.debuggable)" = 1 ]
[ ! -L /data/property/persist.debuggable ]
[ "$(stat -c '%a:%u:%g:%s' /data/property/persist.debuggable)" = 600:0:0:1 ]
[ "$(cat /data/property/persist.debuggable)" = 1 ]
[ -n "$(pidof adbd)" ]
cat /proc/sys/kernel/random/boot_id
''').strip()
        if self.state:
            ram_id = json.loads((self.folder / "ram-ready.json").read_text())["boot_id"]
            if ram_id == out:
                raise ValueError("Stock boot ID did not change")
            write_new(self.folder / ("stock-verified-" + uuid.uuid4().hex + ".json"),
                      dict(boot_id=out, root=True, original_adbd=True, firmware="1.8.1"))
        emit("root_verified", stock_serial=actual, boot_id=out, uid=0, transport="TCP ADB over USB networking", firmware="1.8.1")

    def disable_root(self):
        self.stock_guard()
        # Only undo a recorded absent->1 creation, never somebody else's pre-existing setting.
        inspection = json.loads((self.folder / "inspection.json").read_text())
        if (inspection["state"] != "ABSENT" or
                inspection.get("target") != "/tmp/sc3-stock-data/property/persist.debuggable" or
                not (self.folder / "enabled.json").is_file()):
            raise ValueError("No matching prior absent-property enable record")
        self.trial_engine().verify_snapshot(self.folder)
        if digest(self.folder / "property-before.tar") != inspection["property_archive_sha256"]:
            raise ValueError("Original property archive changed")
        receipt = json.loads((self.folder / "enabled.json").read_text())
        if receipt.get("property") != "persist.debuggable" or receipt.get("value") != "1":
            raise ValueError("Unexpected enable receipt")
        write_new(self.folder / "root-disable-started.json", dict(requested=True))
        self.shell('''[ ! -L /data/property/persist.debuggable ]
[ "$(stat -c '%a:%u:%g:%s' /data/property/persist.debuggable)" = 600:0:0:1 ]
[ "$(cat /data/property/persist.debuggable)" = 1 ]
rm /data/property/persist.debuggable
sync
''')
        write_new(self.folder / "root-disabled.json", dict(property_removed=True, rebooted=False))
        emit("root_disabled", rebooted=False,
             warning="Running ADB/debug state is unchanged until normal reboot; other stock gates may still enable debug.")

    def sumo(self, action):
        self.stock_guard()
        if action == "status":
            out = self.shell('''printf 'service=%s\n' "$(gprop init.svc.mppd)"
sha1sum /usr/bin/mppd
if [ -e /data/lib/mppd/native-sumo/enabled ]; then echo startup=enabled; else echo startup=disabled; fi
if [ -r /tmp/sc3-native-sumo-selection ]; then cat /tmp/sc3-native-sumo-selection; fi
''')
            lines = out.splitlines()
            executable = next((line.split()[0] for line in lines if line.endswith("  /usr/bin/mppd")), None)
            emit("sumo_status", detail=out, executable_sha1=executable,
                 variant={STOCK: "stock", PATCH: "native-sumo-v1c"}.get(executable, "unknown"),
                 service=next((line.split("=", 1)[1] for line in lines if line.startswith("service=")), "unknown"),
                 startup_enabled="startup=enabled" in lines)
            return
        # Refuse an unknown/v2 overlay or startup hook before even staging files.
        self.shell('''s=$(sha1sum /usr/bin/mppd | cut -d ' ' -f 1)
[ "$s" = STOCK ] || [ "$s" = PATCH ]
for d in /data /data/lib /data/lib/mppd /data/lib/mppd/native-sumo /data/lib/mppd/native-sumo-backup; do
 [ ! -L "$d" ]
done
[ ! -L /data/lib/mppd/native-sumo/enabled ]
if [ -e /usr/bin/sc3-native-sumo-start ]; then
 [ "$(sha1sum /usr/bin/sc3-native-sumo-start | cut -d ' ' -f 1)" = SELECTOR ]
fi
[ ! -L /etc/boxinit.d/99-mppd.rc ]
s=$(sha1sum /etc/boxinit.d/99-mppd.rc | cut -d ' ' -f 1)
[ "$s" = STOCK_INIT ] || [ "$s" = NATIVE_INIT ]
'''.replace("STOCK_INIT", STOCK_INIT).replace("NATIVE_INIT", SCRIPT_PINS["assets/99-mppd.native.rc"])
   .replace("STOCK", STOCK).replace("PATCH", PATCH).replace("SELECTOR", self.manifest["files"]["assets/startup.sh"]["sha1"]))
        if action == "install" or action == "remove-hook":
            stage = "/data/lib/mppd/sc3-app-stage-" + uuid.uuid4().hex
            self.shell("umask 077; mkdir " + stage)
            paths = ["device/sumo-tool.sh", "assets/startup.sh", "assets/control.sh",
                     "assets/99-mppd.native.rc", "assets/mppd.native-sumo-v1c"]
            for name in paths:
                remote = stage + "/" + Path(name).name
                self.process(self.adb + ["push", str(HERE / name), remote], 20)
                self.shell("[ \"$(sha1sum " + remote + " | cut -d ' ' -f 1)\" = " +
                           self.manifest["files"][name]["sha1"] + " ]")
            output = self.shell("sh " + stage + "/sumo-tool.sh " + action, 30)
        else:
            control = "/data/lib/mppd/native-sumo/control.sh"
            expected = self.manifest["files"]["assets/control.sh"]["sha1"]
            self.shell("[ ! -L " + control + " ]; [ \"$(sha1sum " + control +
                       " | cut -d ' ' -f 1)\" = " + expected + " ]")
            output = self.shell("mkdir /tmp/sc3-app-maintenance.lock\n"
                "trap '/bin/busybox rmdir /tmp/sc3-app-maintenance.lock' EXIT\n"
                "trap 'exit 130' HUP INT TERM\nsh " + control + " " + action, 20)
        emit("sumo_complete", action=action, detail=output,
             automatic_startup={"install": True, "enable": True, "disable": False,
                                "stock": False, "remove-hook": False}.get(action),
             daemon_restart_possible=action in ("activate", "stock", "remove-hook"),
             reboot_requested=False, movement_packets_sent=False,
             warning="Read status to distinguish visible executable, running service and future startup. No drive/jump packet sent.")


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("operation", choices=("verify-bundle", "prepare-root", "wait-fastboot", "boot-root", "snapshot-root",
        "inspect-root", "enable-root", "return-stock", "verify-root", "verify-root-adb", "disable-root", "sumo-status",
        "sumo-install", "sumo-enable", "sumo-disable", "sumo-activate", "sumo-stock", "sumo-remove-hook"))
    p.add_argument("--adb", default="adb", help="App should supply an absolute bundled platform-tools path")
    p.add_argument("--fastboot", default="fastboot")
    p.add_argument("--adb-port", type=int, default=5038)
    p.add_argument("--endpoint", default="192.168.53.1:9050")
    p.add_argument("--stock-serial")
    p.add_argument("--fastboot-serial")
    p.add_argument("--session", type=Path)
    p.add_argument("--experimental-device", action="store_true", help=argparse.SUPPRESS)  # Legacy no-op; no spare-only gate.
    p.add_argument("--confirm-write", action="store_true", help="Explicit user consent, including reboot/RAM boot/UBI attachment")
    p.add_argument("--sumo-off", action="store_true", help="Owner confirmed Sumo is off before native daemon maintenance")
    return p


def main(argv=None):
    os.umask(0o077)
    args = parser().parse_args(argv)
    operation = args.operation
    try:
        if not 1024 <= args.adb_port <= 65535:
            raise ValueError("Invalid local ADB server port")
        read_only = operation in ("verify-bundle", "prepare-root", "wait-fastboot", "verify-root", "verify-root-adb", "sumo-status")
        if not read_only and not args.confirm_write:
            raise ValueError("Explicit --confirm-write is required; no device command issued")
        if operation.startswith("sumo-") and not read_only and not args.sumo_off:
            raise ValueError("--sumo-off confirmation required; no device command issued")
        tool = Tool(args)
        emit("started", operation=operation)
        if operation == "verify-bundle":
            emit("bundle_verified", files=len(tool.manifest["files"]), firmware="1.8.1", hardware="3")
        elif operation == "prepare-root":
            tool.prepare()
        elif operation.startswith("sumo-"):
            tool.sumo(operation.removeprefix("sumo-"))
        elif operation in ("verify-root", "verify-root-adb") and not args.session:
            getattr(tool, "verify_root" if operation == "verify-root" else "verify_root_adb")()
        else:
            with tool.session():
                if operation == "wait-fastboot": tool.select_fastboot()
                elif operation == "boot-root": tool.boot()
                elif operation in ("snapshot-root", "inspect-root", "enable-root"): tool.root_phase(operation)
                elif operation == "return-stock": tool.return_stock()
                elif operation == "verify-root": tool.verify_root()
                elif operation == "verify-root-adb": tool.verify_root_adb()
                elif operation == "disable-root": tool.disable_root()
        emit("completed", operation=operation)
        return 0
    except (OSError, ValueError, TypeError, RuntimeError, KeyError, subprocess.TimeoutExpired) as exc:
        emit("error", operation=operation, code="STOP_NO_AUTOMATIC_RETRY", message=str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
