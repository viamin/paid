"""Private process-snapshot contracts, not real worker adoption evidence.

@spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from worker_admission import AdmissionError
import worker_admission_cohort as cohort


class CohortTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.proc = self.root / "proc"
        self.proc.mkdir()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.status = "PROCESS PID STATUS\nweb 99 running\nworker_poll 10 running\nworker_agent 20 running\n"
        self.process(10, 1, 100)
        self.process(11, 10, 101)
        self.process(12, 11, 102, mode="poll")
        self.process(20, 1, 200)
        self.process(21, 20, 201, mode="agent")

    def tearDown(self):
        self.temporary.cleanup()

    def process(self, pid, parent, ticks, *, mode=None, environment_mode=None, workspace=None, arguments=None):
        directory = self.proc / str(pid)
        directory.mkdir(exist_ok=True)
        fields = ["S", str(parent)] + ["0"] * 17 + [str(ticks)]
        (directory / "stat").write_text(f"{pid} (name (with) spaces) " + " ".join(fields))
        args = arguments or (["ruby", "bin/temporal_worker", "--mode=" + mode] if mode else ["sh"])
        (directory / "cmdline").write_bytes(b"\0".join(value.encode() for value in args) + b"\0")
        env = b"TEMPORAL_WORKER_MODE=" + environment_mode.encode() + b"\0" if environment_mode else b""
        (directory / "environ").write_bytes(env)
        cwd = directory / "cwd"
        cwd.unlink(missing_ok=True)
        cwd.symlink_to(workspace or self.workspace)

    def discover(self):
        return cohort.discover_cohort(self.workspace, self.status, proc_root=self.proc)

    def test_resolves_nested_wrapper_workers_and_ignores_unrelated_status_rows(self):
        self.assertEqual(self.discover(), {"poll": {"pid": 12, "start_ticks": 102},
                                           "agent": {"pid": 21, "start_ticks": 201}})

    def test_default_both_mode_coalesces_one_live_supervised_process(self):
        self.status = "PROCESS PID STATUS\nworker_poll 10 running\n"
        for path in (self.proc / "21").iterdir():
            path.unlink()
        (self.proc / "21").rmdir()
        self.process(12, 11, 102, arguments=["ruby", "bin/temporal_worker"])
        self.assertEqual(self.discover(), {role: {"pid": 12, "start_ticks": 102} for role in ("poll", "agent")})

    def test_both_mode_readiness_paths_match_the_actual_ruby_producer_for_default_and_explicit_launches(self):
        source = Path(__file__).resolve().parents[2]
        cohort_identity = {role: {"pid": 12, "start_ticks": 102} for role in ("poll", "agent")}
        for arguments, configured_mode in (([], None), (["--mode=both"], "both")):
            with self.subTest(configured_mode=configured_mode):
                environment = dict(os.environ)
                if configured_mode is None:
                    environment.pop("TEMPORAL_WORKER_MODE", None)
                else:
                    environment["TEMPORAL_WORKER_MODE"] = configured_mode
                producer_name = subprocess.check_output(
                    ["bundle", "exec", "ruby", "-Ilib", "-ractive_support/core_ext/object/blank",
                     "-rpaid/temporal_worker_config", "-rpaid/worker_readiness", "-e",
                     '$PROGRAM_NAME = "bin/temporal_worker"; Paid::TemporalWorkerConfig.bind_launch_mode!(ARGV, ENV); print Paid::WorkerReadiness.default_file_name',
                     "--",
                     *arguments],
                    cwd=source, env=environment, text=True
                )
                self.assertEqual(producer_name, "paid-worker-ready-temporal_worker-both")
                (self.root / producer_name).touch()
                paths = cohort.readiness_paths(cohort_identity, self.root)
                self.assertEqual(paths, {role: str(self.root / producer_name) for role in ("poll", "agent")})
                (self.root / producer_name).unlink()

    def test_legacy_unsuffixed_both_marker_defers_instead_of_acknowledging_an_unknown_contract(self):
        cohort_identity = {role: {"pid": 12, "start_ticks": 102} for role in ("poll", "agent")}
        (self.root / "paid-worker-ready-temporal_worker").touch()

        with self.assertRaises(AdmissionError):
            cohort.readiness_paths(cohort_identity, self.root)

    def test_conflicting_launch_mode_and_environment_are_unknown(self):
        self.process(12, 11, 102, mode="poll", environment_mode="agent")
        with self.assertRaises(AdmissionError):
            self.discover()

    def test_missing_or_malformed_or_dead_supervisor_never_proves_absence(self):
        for status in ("", "unparseable success", "PROCESS PID STATUS\nworker_poll 10 dead\nworker_agent 20 running\n",
                       "PROCESS PID STATUS\nworker_poll 10 running\nworker_poll 11 running\nworker_agent 20 running\n"):
            with self.subTest(status=status):
                self.status = status
                with self.assertRaises(AdmissionError):
                    self.discover()

    def test_genuine_orphan_worker_is_not_covered_by_valid_supervised_markers(self):
        self.process(30, 1, 300, mode="poll")
        with self.assertRaises(AdmissionError):
            self.discover()

    def test_unknown_worker_arguments_are_not_silently_defaulted(self):
        self.process(12, 11, 102, arguments=["ruby", "bin/temporal_worker", "--mode=poll", "--unexpected"])
        with self.assertRaises(AdmissionError):
            self.discover()

    def test_an_unrelated_workspace_worker_is_not_adopted(self):
        other = self.root / "other"
        other.mkdir()
        self.process(30, 1, 300, mode="poll", workspace=other)
        self.assertEqual(self.discover()["poll"]["pid"], 12)
        self.process(12, 11, 102, mode="poll", workspace=other)
        with self.assertRaises(AdmissionError):
            self.discover()

    def test_environment_mode_uses_the_same_public_worker_launch_contract(self):
        self.process(12, 11, 102, arguments=["ruby", "bin/temporal_worker"], environment_mode="poll")
        self.assertEqual(self.discover()["poll"]["pid"], 12)


if __name__ == "__main__":
    unittest.main(verbosity=2)
