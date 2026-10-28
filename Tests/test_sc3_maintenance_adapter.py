"""Host-only adapter fixtures. No actual ADB, fastboot, root phase or USB call."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

ROOT = Path(__file__).resolve().parents[1]
ENTRY = ROOT / "Resources/SC3Maintenance/entry.py"
SPEC = importlib.util.spec_from_file_location("sc3_maintenance_adapter_test", ENTRY)
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)


class AdapterTests(unittest.TestCase):
    def test_pinned_bundle_contains_only_manifest_assets(self):
        tools = ENTRY.parent / "tools"
        data = (tools / "manifest.json").read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), "f732b9b5b94df921c3c6c5623845b390e35a0125177cfa8cfc5afeeb06d16e76")
        manifest = json.loads(data)
        self.assertEqual(len(manifest["files"]), 10)
        actual = {str(p.relative_to(tools)) for p in tools.rglob("*") if p.is_file()}
        self.assertEqual(actual, set(manifest["files"]) | {"manifest.json"})
        for name, row in manifest["files"].items():
            self.assertEqual(hashlib.sha256((tools / name).read_bytes()).hexdigest(), row["sha256"])
        self.assertEqual(manifest["files"]["assets/sc3-ramdiag-v5.img"]["sha256"], "1af51a48d6523902baf589574b6e56daba3134dd48a7514558c9a6253511c3a0")
        self.assertEqual(manifest["files"]["assets/mppd.native-sumo-v1c"]["sha256"], "f561113254ea50465eca823b6b1ebb8d3acefddb9f0920043fc960c4218a5c96")

    def test_packaged_fastboot_detection_needs_no_manual_serial_or_adb_server(self):
        with tempfile.TemporaryDirectory(prefix="sc3 automatic identity ") as temp:
            session = Path(temp) / "session"; session.mkdir(mode=0o700)
            (session / "session.json").write_text(json.dumps(dict(format="sc3-app-session-v1",
                endpoint="192.168.53.1:9050", adb_port=5038, stock_serial="NEWCONTROLLER",
                fastboot_serial=None, ram_sha256="1af51a48d6523902baf589574b6e56daba3134dd48a7514558c9a6253511c3a0")))
            fastboot = Path(temp) / "fixture fastboot"
            fastboot.write_text("#!/bin/sh\n[ \"$#\" = 1 ] && [ \"$1\" = devices ] || exit 1\nprintf 'NEWFASTBOOT\\tfastboot\\n'\n")
            fastboot.chmod(0o700)
            result = subprocess.run([sys.executable, "-I", "-B", str(ENTRY), "wait-fastboot",
                "--adb", "/usr/bin/false", "--fastboot", str(fastboot), "--session", str(session)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual([row["event"] for row in rows], ["started", "fastboot_ready", "completed"])
            self.assertEqual(rows[1]["serial"], "NEWFASTBOOT")
            self.assertEqual(json.loads((session / "fastboot-selected.json").read_text())["stock_serial"], "NEWCONTROLLER")

    def test_existing_server_segmented_response_and_protocol(self):
        connection = MagicMock()
        parts = iter([b"OK", b"AY", b"00", b"04", b"00", b"29"])
        connection.recv.side_effect = lambda _: next(parts)
        connection.__enter__.return_value = connection
        with patch.object(ADAPTER.socket, "create_connection", return_value=connection) as connect:
            ADAPTER.server_check(5038)
            connect.assert_called_once_with(("127.0.0.1", 5038), timeout=1)
            connection.sendall.assert_called_once_with(b"000chost:version")

    def test_web_verification_does_not_check_or_connect_adb_server(self):
        import runpy
        scope = runpy.run_path(str(ENTRY.parent / "tools/sc3_tool.py"), run_name="adapter_web_fixture")
        argv = ["verify-root", "--adb", "/usr/bin/false", "--fastboot", "/usr/bin/false"]
        with patch.object(ADAPTER.runpy, "run_path", return_value=scope), \
                patch.object(scope["Tool"], "verify_root") as verify, \
                patch.object(ADAPTER, "server_check", side_effect=AssertionError("No server check")), \
                patch.object(ADAPTER.subprocess, "run", side_effect=AssertionError("No ADB connect")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ADAPTER.main(argv), 0)
            verify.assert_called_once_with()

    def test_wrong_or_closed_server_is_stop_not_daemon_management(self):
        for replies in ([b"FAIL"], [b"OKAY", b"0004", b"0028"], [b""]):
            connection = MagicMock(); connection.__enter__.return_value = connection
            connection.recv.side_effect = replies
            with patch.object(ADAPTER.socket, "create_connection", return_value=connection), patch.object(ADAPTER.subprocess, "run") as child:
                with self.assertRaises(RuntimeError): ADAPTER.server_check(5038)
                child.assert_not_called()

    def contract(self, changed="", video="0", active="none"):
        rows = "\n".join([
            "0be1f74b8829fb66d07a8401fd7330b4a5016d87  /usr/bin/sc3-native-sumo-start",
            "5e6af16f7bddfdf0c604c364a3e6d129497ff07f  /etc/boxinit.d/99-mppd.rc",
            "1b22641d969a0a2fef45d72d1f51bd4ab5c66b99  /data/lib/mppd/native-sumo/control.sh",
            "VIDEO_V2=" + video, "ACTIVE=" + active,
        ])
        if changed: rows = rows.replace("0be1f74b8829fb66d07a8401fd7330b4a5016d87", changed)
        tool = MagicMock(); tool.shell.return_value = rows
        return tool

    def test_stock_or_v1c_contract_keeps_running_service_separate(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            ADAPTER.sumo_contract(self.contract(active="none"))
        event = json.loads(output.getvalue())
        self.assertTrue(event["compatible"])
        self.assertEqual(event["active_variant"], "not running")

    def test_new_video_selector_preload_unknown_process_refused(self):
        for tool in (self.contract(changed="foreign-selector"), self.contract(video="1"), self.contract(active="foreign-process"), self.contract(video="unknown")):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaises(RuntimeError): ADAPTER.sumo_contract(tool)
            self.assertFalse(json.loads(output.getvalue())["compatible"])
            code = tool.shell.call_args.args[0]
            for forbidden in ("pstart", "pstop", "reboot", "mount -o", "rm ", "push"):
                self.assertNotIn(forbidden, code)

    def test_runtime_missing_zone_data_reports_json_without_transport(self):
        import zoneinfo
        with patch.object(zoneinfo, "ZoneInfo", side_effect=KeyError("missing Europe/Athens")), patch.object(ADAPTER.subprocess, "run") as child, contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(ADAPTER.main(["runtime-check", "--adb", "/abs/adb", "--fastboot", "/abs/fastboot"]), 1)
            child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["event"], "error")


if __name__ == "__main__": unittest.main(verbosity=2)
