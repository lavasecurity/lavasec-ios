"""Exercise the real EXIT cleanup with a fake simctl; no Xcode required."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / "ReactNative/scripts/simulator-cleanup.sh"
UDID = "12345678-1234-1234-1234-123456789ABC"


class SimulatorCleanupTests(unittest.TestCase):
    def run_cleanup(self, shutdown_status=0, delete_status=0, exit_status=0, bad_log=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = root / "xcrun"
            fake.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >>"$CALLS"
case "$2" in
  shutdown) echo 'shutdown diagnostic'; exit "$SHUTDOWN_STATUS" ;;
  delete) echo 'delete diagnostic'; exit "$DELETE_STATUS" ;;
  *) exit 99 ;;
esac
''')
            fake.chmod(0o755)
            log = root if bad_log else root / "cleanup.log"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "CALLS": str(root / "calls"), "SHUTDOWN_STATUS": str(shutdown_status),
                   "DELETE_STATUS": str(delete_status)}
            result = subprocess.run(["bash", "-c", '''
set -euo pipefail
source "$1"
trap 'cleanup_simulator "$2" "$3"' EXIT
exit "$4"
''', "test", str(HELPER), UDID, str(log), str(exit_status)],
                env=env, capture_output=True, text=True)
            calls = (root / "calls").read_text().splitlines()
            text = "" if bad_log else log.read_text()
        self.assertEqual(calls, [f"simctl shutdown {UDID}", f"simctl delete {UDID}"])
        return result, text

    def test_success_logs_both_commands(self):
        result, log = self.run_cleanup()
        self.assertEqual(result.returncode, 0)
        self.assertIn(f"shutdown {UDID} status=0", log)
        self.assertIn(f"delete {UDID} status=0", log)
        self.assertIn("delete diagnostic", log)
        self.assertNotIn("::warning::", result.stderr)

    def test_already_shutdown_does_not_prevent_deletion_or_replace_build_failure(self):
        result, log = self.run_cleanup(shutdown_status=148, exit_status=17)
        self.assertEqual(result.returncode, 17)
        self.assertIn("status=148", log)
        self.assertIn("shutdown diagnostic", log)
        self.assertNotIn("::warning::", result.stderr)

    def test_failed_delete_warns_and_preserves_original_build_status(self):
        for original in (0, 17):
            with self.subTest(original=original):
                result, log = self.run_cleanup(delete_status=1, exit_status=original)
                self.assertEqual(result.returncode, original)
                self.assertIn(f"delete {UDID} status=1", log)
                self.assertIn(f"::warning::Simulator cleanup failed for {UDID}", result.stderr)

    def test_unwritable_evidence_does_not_prevent_delete_or_replace_status(self):
        result, _ = self.run_cleanup(bad_log=True, exit_status=17)
        self.assertEqual(result.returncode, 17)
        self.assertIn(f"[sim-cleanup] deleted {UDID}", result.stdout)


if __name__ == "__main__":
    unittest.main()
