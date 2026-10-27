#!/usr/bin/env python3
"""Signed Mac adapter. V5/v1c payloads remain unchanged; identities are detected."""
import sys
sys.dont_write_bytecode = True
import json
import pathlib
import re
import runpy
import socket
import subprocess


def emit(event, **fields):
    print(json.dumps(dict(api=1, event=event, **fields)), flush=True)


def server_check(port):
    with socket.create_connection(("127.0.0.1", port), timeout=1) as connection:
        connection.settimeout(2)
        connection.sendall(b"000chost:version")
        def read(count):
            value = b""
            while len(value) < count:
                part = connection.recv(count - len(value))
                if not part: raise RuntimeError("Existing ADB server closed; STOP")
                value += part
            return value
        if read(4) != b"OKAY" or read(4) != b"0004" or read(4) != b"0029":
            raise RuntimeError("Existing ADB protocol differs; never replace the owner's server")


def sumo_contract(tool):
    # Read-only additional protection for the separate in-progress v2/video path.
    text = tool.shell('''
for f in /usr/bin/sc3-native-sumo-start /etc/boxinit.d/99-mppd.rc /data/lib/mppd/native-sumo/control.sh; do
 if [ -L "$f" ]; then echo SYMLINK; elif [ -e "$f" ]; then sha1sum "$f"; else echo "ABSENT $f"; fi
done
p=$(pidof mppd || true)
case "$p" in '') echo VIDEO_V2=0; echo ACTIVE=none;; *[!0-9]*) echo VIDEO_V2=unknown; echo ACTIVE=unknown;; *)
 echo "ACTIVE=$(sha1sum /proc/$p/exe | cut -d ' ' -f 1)"
 if [ ! -r "/proc/$p/maps" ]; then echo VIDEO_V2=unknown
 elif grep -q 'libsc3-sumo-native-v2' "/proc/$p/maps"; then echo VIDEO_V2=1
 else echo VIDEO_V2=0; fi;; esac
''')
    allowed = {
        "/usr/bin/sc3-native-sumo-start": {"ABSENT", "0be1f74b8829fb66d07a8401fd7330b4a5016d87"},
        "/etc/boxinit.d/99-mppd.rc": {"bcd89c78ce123680b3c40f3dbbaf61fffb54b0fc", "5e6af16f7bddfdf0c604c364a3e6d129497ff07f"},
        "/data/lib/mppd/native-sumo/control.sh": {"ABSENT", "1b22641d969a0a2fef45d72d1f51bd4ab5c66b99"},
    }
    values = {}
    for line in text.splitlines():
        pair = line.split()
        if len(pair) == 2 and pair[1] in allowed and pair[1] not in values: values[pair[1]] = pair[0]
    active_rows = [line[7:] for line in text.splitlines() if line.startswith("ACTIVE=")]
    active = active_rows[0] if len(active_rows) == 1 else "unknown"
    variants = {"none": "not running", "52398949fe32b46b0251b2c7f63942593c068d62": "stock", "83874fd41722c8391b3e530c7fce0e2ff3bab461": "native-sumo-v1c"}
    compatible = len(values) == len(allowed) and all(values[key] in accepted for key, accepted in allowed.items()) and text.splitlines().count("VIDEO_V2=0") == 1 and "SYMLINK" not in text and active in variants
    emit("sumo_contract", compatible=compatible, contract="v1c-only", video_extension_active="VIDEO_V2=1" in text, active_sha1=active, active_variant=variants.get(active, "unknown"))
    if not compatible:
        raise RuntimeError("STOP: newer/unknown selector, init/control script or active native video extension. The v1c manager will not downgrade it.")


def main(argv):
    operation = argv[0] if argv else ""
    try:
        if sys.version_info < (3, 9): raise RuntimeError("Choose Python 3.9 or newer")
        from zoneinfo import ZoneInfo
        ZoneInfo("Europe/Athens")
        if operation == "runtime-check":
            emit("started", operation=operation)
            for name in ("--adb", "--fastboot"):
                value = argv[argv.index(name) + 1]
                if not pathlib.Path(value).is_absolute(): raise RuntimeError("Absolute platform-tools paths required")
                result = subprocess.run([value, "version" if name == "--adb" else "--version"], capture_output=True, timeout=4, check=True)
                if name == "--adb" and not result.stdout.startswith(b"Android Debug Bridge version 1.0.41\n"):
                    raise RuntimeError("ADB protocol 41 client required; existing server will not be replaced")
            emit("runtime_ready", python=list(sys.version_info[:3]), zone="Europe/Athens")
            emit("completed", operation=operation); return 0
        scope = runpy.run_path(str(pathlib.Path(__file__).parent / "tools/sc3_tool.py"), run_name="parrotlab_sc3_tool")
        args = scope["parser"]().parse_args(argv)
        adb = str(pathlib.Path(args.adb)); fastboot = str(pathlib.Path(args.fastboot))
        if not pathlib.Path(adb).is_absolute() or not pathlib.Path(fastboot).is_absolute(): raise RuntimeError("Absolute platform-tools paths required")
        if operation == "verify-root":
            return scope["main"](argv)  # HTTP only; even a stale/missing ADB server is irrelevant.
        original_popen = subprocess.Popen
        if operation not in ("verify-bundle", "prepare-root", "wait-fastboot"):
            server_check(args.adb_port)
        class GuardedProcess(original_popen):
            def __init__(self, command, *positional, **keyword):
                if not isinstance(command, (list, tuple)): raise RuntimeError("Argument arrays required")
                command = list(command)
                if command and command[0] == adb:
                    server_check(args.adb_port)
                    # Numeric loopback disables ADB's automatic local-server launch.
                    command[1:1] = ["-H", "127.0.0.1"]
                super().__init__(command, *positional, **keyword)
        subprocess.Popen = GuardedProcess
        tool_type = scope["Tool"]
        original_sumo = tool_type.sumo
        def guarded_sumo(tool, action):
            tool.stock_guard()
            if action != "status": sumo_contract(tool)
            original_sumo(tool, action)
            if action == "status": sumo_contract(tool)
            else:
                original_sumo(tool, "status")
                sumo_contract(tool)
        tool_type.sumo = guarded_sumo
        if operation == "verify-root-adb":
            # One bounded, selected reconnect. Its exit0 is never considered
            # success: original stock_guard/verify-root must still prove identity.
            subprocess.run([adb, "-P", str(args.adb_port), "connect", args.endpoint], capture_output=True, timeout=4)
        return scope["main"](argv)
    except (OSError, ValueError, RuntimeError, KeyError, IndexError, subprocess.SubprocessError) as error:
        emit("error", operation=operation, code="STOP_NO_AUTOMATIC_RETRY", message=str(error)); return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
