"""Actual Bash/controller process contracts, without SDK or service operations.

@spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


class ConsumerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        source = Path(__file__).resolve().parents[2]
        (self.root / "bin/lib").mkdir(parents=True)
        for name in ("worker_admission.py", "worker_admission_cohort.py", "dev_worker_admission.sh", "dev_supervisor.sh"):
            shutil.copyfile(source / "bin/lib" / name, self.root / "bin/lib" / name)
        shutil.copyfile(source / "bin/dev-update", self.root / "bin/dev-update")
        (self.root / "tmp").mkdir()
        self.status = self.root / "status"
        self.workers = []
        self.scripts = []
        (self.root / "bin/temporal_worker").write_text('''require "json"
require "securerandom"
mode = ARGV.fetch(0).delete_prefix("--mode=")
pid = Process.pid
ticks = File.read("/proc/#{pid}/stat").split(") ", 2).last.split.fetch(19).to_i
profile = %w[activity_slots activity_task_polls local_activity_slots workflow_slots workflow_task_polls].to_h { |key| [key, 1] }
revision = ENV.fetch("FIXTURE_REVISION")
roles = mode == "both" ? %w[poll agent] : [mode]
admission = {protocol: 1, scope: "paid-workflow-and-remote-activity", pid: pid, process_start_ticks: ticks, workspace: Dir.pwd, revision: revision, boot_id: SecureRandom.uuid, profiles: roles.to_h { |role| [role, profile] }}
suffix = ENV["TEMPORAL_WORKER_MODE"] ? "-#{ENV.fetch("TEMPORAL_WORKER_MODE")}" : ""
path = File.join(ENV.fetch("TMPDIR"), "paid-worker-ready-temporal_worker#{suffix}")
File.write(path, JSON.generate({pid: pid, revision: revision, admission: admission}))
$stdout.sync = true
puts pid
sleep 30
''')
        (self.root / "bin/overmind").write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> overmind-calls\ncat "$FIXTURE_STATUS"\n')
        (self.root / "bin/overmind").chmod(0o755)
        (self.root / "bin/git").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> git-calls\nif [ "$*" = "rev-parse HEAD" ]; then printf "%s\\n" "' + "b" * 40 + '"; else exit 87; fi\n')
        (self.root / "bin/git").chmod(0o755)
        self.start_workers("a" * 40)

    def start_workers(self, revision, both=False, explicit_both=False):
        current = []
        modes = ("both",) if both else ("poll", "agent")
        for role in modes:
            environment = dict(os.environ, TMPDIR=str(self.root / "tmp"), FIXTURE_REVISION=revision)
            if not both or explicit_both:
                environment["TEMPORAL_WORKER_MODE"] = role
            worker = subprocess.Popen(["ruby", "bin/temporal_worker", "--mode=" + role], cwd=self.root,
                                      env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.workers.append(worker)
            current.append(worker)
            self.assertEqual(int(worker.stdout.readline()), worker.pid)
        self.status.write_text("PROCESS PID STATUS\n" + "".join(
            "worker_" + role + " " + str(worker.pid) + " running\n"
            for role, worker in zip(("poll",) if both else ("poll", "agent"), current)))
        return current

    def script(self, code):
        environment = dict(os.environ, TMPDIR=str(self.root / "tmp"), FIXTURE_STATUS=str(self.status),
                           PATH=str(self.root / "bin") + ":" + os.environ["PATH"])
        header = '''set -euo pipefail
APP_ROOT="$PWD"
log() { printf '%s\\n' "$*" >&2; }
dev_supervisor_run_overmind() { "$@"; }
source bin/lib/dev_worker_admission.sh
trap worker_admission_cleanup EXIT
'''
        script = subprocess.Popen(["bash", "-c", header + code], cwd=self.root, env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.scripts.append(script)
        return script

    def finish(self, script, expected=0):
        output, errors = script.communicate(timeout=10)
        self.assertEqual(script.returncode, expected, output + errors)
        return output

    def updater(self):
        environment = dict(os.environ, TMPDIR=str(self.root / "tmp"), FIXTURE_STATUS=str(self.status),
                           PATH=str(self.root / "bin") + ":" + os.environ["PATH"])
        script = subprocess.Popen(["bash", "bin/dev-update", "--recover"], cwd=self.root, env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.scripts.append(script)
        return script

    def requests(self):
        return list((self.root / "tmp").glob("*.admission.request"))

    def wait_ready(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if (self.root / "ready").exists():
                return
            time.sleep(0.01)
        self.fail("Bash caller did not reach its owned acknowledgement")

    def test_ack_abort_and_non_inherited_control_pipes(self):
        script = self.script('''worker_admission_begin ''' + "b" * 40 + '''
reader=$(readlink "/proc/$$/fd/$WORKER_ADMISSION_READ_FD")
writer=$(readlink "/proc/$$/fd/$WORKER_ADMISSION_WRITE_FD")
python3 -c 'import os,sys; values=[]
for name in os.listdir("/proc/self/fd"):
 try: values.append(os.readlink("/proc/self/fd/"+name))
 except FileNotFoundError: pass
assert not set(sys.argv[1:]).intersection(values)' "$reader" "$writer"
''')
        self.finish(script)
        self.assertFalse(self.requests())
        self.assertEqual(json.loads((self.root / "tmp/worker-admission.json").read_text())["phase"], "aborted")

    def test_legacy_capability_refuses_before_request_or_service_stop(self):
        for path in (self.root / "tmp").glob("paid-worker-ready-*"):
            value = json.loads(path.read_text())
            del value["admission"]
            path.write_text(json.dumps(value))
        self.finish(self.script("worker_admission_begin " + "b" * 40), expected=1)
        self.assertFalse(self.requests())

    def test_lost_post_ack_caller_preserves_generation_and_recovery_can_abort(self):
        self.finish(self.script("worker_admission_begin " + "b" * 40 + "\nWORKER_ADMISSION_STOPPING=1\nexit 7\n"), expected=7)
        self.assertEqual(len(self.requests()), 4)
        self.finish(self.script("worker_admission_begin " + "b" * 40 + " recover\n"))
        self.assertFalse(self.requests())

    def test_changed_supervisor_cohort_refuses_before_stop(self):
        script = self.script("worker_admission_begin " + "b" * 40 + '''
touch ready
for i in $(seq 1 250); do [ ! -f go ] || break; sleep .02; done
worker_admission_before_stop
''')
        self.wait_ready()
        self.status.write_text("PROCESS PID STATUS\nworker_poll 999999 running\nworker_agent 999998 running\n")
        (self.root / "go").touch()
        self.finish(script, expected=1)
        self.assertFalse(self.requests())

    def test_original_exit_wait_refuses_live_instances_then_accepts_actual_absence(self):
        script = self.script("worker_admission_begin " + "b" * 40 + '''
deadline=$(python3 -c 'import time; print(time.monotonic()+.05)')
if worker_admission_wait_originals "$deadline"; then exit 9; fi
touch ready
for i in $(seq 1 250); do [ ! -f go ] || break; sleep .02; done
deadline=$(python3 -c 'import time; print(time.monotonic()+2)')
worker_admission_wait_originals "$deadline"
WORKER_ADMISSION_STOPPING=1
''')
        self.wait_ready()
        for worker in self.workers:
            worker.terminate()
            worker.wait(timeout=2)
        (self.root / "go").touch()
        self.finish(script)
        self.assertEqual(len(self.requests()), 4)

    def test_reaper_refuses_reused_or_foreign_identity_without_signalling_bystander(self):
        worker = self.workers[0]
        stat = Path("/proc", str(worker.pid), "stat").read_text().split(") ", 1)[1].split()
        identity = {"pid": worker.pid, "start_ticks": int(stat[19]), "parent": int(stat[1])}
        for field in ("start_ticks", "parent"):
            wrong = dict(identity)
            wrong[field] += 1
            result = subprocess.run(["python3", str(self.root / "bin/lib/worker_admission_cohort.py"),
                                     "--workspace", str(self.root), "--reap-controller", json.dumps(wrong)],
                                    capture_output=True, text=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)["original_absent"])
            self.assertIsNone(worker.poll())

    def test_replacement_keeps_fence_through_setup_and_resumes_only_target_boots(self):
        old = list(self.workers)
        script = self.script("worker_admission_begin " + "b" * 40 + '''
worker_admission_before_stop
touch ready
for i in $(seq 1 250); do [ ! -f go ] || break; sleep .02; done
worker_admission_checkpoint stopped
worker_admission_checkpoint setup
worker_admission_checkpoint starting
worker_admission_resume ''' + "b" * 40 + "\n")
        self.wait_ready()
        self.assertEqual(len(self.requests()), 4)
        for worker in old:
            worker.terminate()
            worker.wait(timeout=2)
        self.start_workers("b" * 40)
        self.assertEqual(len(self.requests()), 4)
        (self.root / "go").touch()
        self.finish(script)
        self.assertFalse(self.requests())
        journal = json.loads((self.root / "tmp/worker-admission.json").read_text())
        self.assertEqual(journal["phase"], "resumed")
        self.assertEqual(journal["update_phase"], "complete")

    def replacement(self, before_both, after_both, before_explicit_both=False, after_explicit_both=False):
        if before_both:
            for worker in self.workers:
                worker.terminate()
                worker.wait(timeout=2)
            self.start_workers("a" * 40, both=True, explicit_both=before_explicit_both)
        old = [worker for worker in self.workers if worker.poll() is None]
        script = self.script("worker_admission_begin " + "b" * 40 + '''
worker_admission_before_stop
touch ready
for i in $(seq 1 250); do [ ! -f go ] || break; sleep .02; done
worker_admission_checkpoint stopped
worker_admission_checkpoint setup
worker_admission_checkpoint starting
worker_admission_resume ''' + "b" * 40 + "\n")
        self.wait_ready()
        self.assertEqual(len(self.requests()), 4)
        for worker in old:
            worker.terminate()
            worker.wait(timeout=2)
        self.start_workers("b" * 40, both=after_both, explicit_both=after_explicit_both)
        self.assertEqual(len(self.requests()), 4)
        (self.root / "go").touch()
        self.finish(script)
        self.assertFalse(self.requests())

    def test_both_to_split_replacement_covers_target_launch_paths(self):
        self.replacement(True, False)

    def test_split_to_both_replacement_covers_target_launch_paths(self):
        self.replacement(False, True)

    def test_explicit_both_replacement_uses_the_producer_marker_and_keeps_every_target_path_fenced(self):
        self.replacement(True, True, before_explicit_both=True, after_explicit_both=True)

    def test_stopped_recovery_resumes_target_after_repeating_incomplete_setup(self):
        script = self.script("worker_admission_begin " + "b" * 40 + '''
worker_admission_before_stop
touch ready
for i in $(seq 1 250); do [ ! -f go ] || break; sleep .02; done
worker_admission_checkpoint stopped
worker_admission_checkpoint setup
exit 7
''')
        self.wait_ready()
        for worker in self.workers:
            worker.terminate()
            worker.wait(timeout=2)
        self.status.write_text("PROCESS PID STATUS\n")
        (self.root / "go").touch()
        self.finish(script, expected=7)
        (self.root / "ready").unlink()
        (self.root / "go").unlink()
        recovery = self.script("worker_admission_begin " + "b" * 40 + ''' recover stopped
test "$(worker_admission_recovery_cohort)" = stopped
touch ready
for i in $(seq 1 250); do [ ! -f go ] || break; sleep .02; done
worker_admission_checkpoint setup
worker_admission_checkpoint starting
worker_admission_resume ''' + "b" * 40 + "\n")
        self.wait_ready()
        self.start_workers("b" * 40)
        (self.root / "go").touch()
        self.finish(recovery)
        self.assertFalse(self.requests())

    def test_completed_recovery_does_not_stop_or_create_a_new_generation(self):
        self.replacement(False, False)
        original = json.loads((self.root / "tmp/worker-admission.json").read_text())
        script = self.script("worker_admission_begin " + "b" * 40 + ''' recover
test "$WORKER_ADMISSION_ALREADY_COMPLETE" = 1
if worker_admission_before_stop; then exit 9; fi
worker_admission_resume ''' + "b" * 40 + "\n")
        self.finish(script)
        current = json.loads((self.root / "tmp/worker-admission.json").read_text())
        self.assertEqual(current["generation"], original["generation"])
        self.assertEqual(current["phase"], "resumed")
        self.assertFalse(self.requests())

    def test_normal_recovery_command_refuses_without_a_recorded_generation(self):
        self.finish(self.updater(), expected=1)
        self.assertIn("valid recorded admission generation", (self.root / "log/dev-update/dev-update.log").read_text())
        self.assertTrue(all(worker.poll() is None for worker in self.workers))
        self.assertFalse((self.root / "git-calls").exists())
        self.assertFalse((self.root / "overmind-calls").exists())

    def test_normal_recovery_command_verifies_completion_without_pull_setup_or_stop(self):
        self.replacement(False, False)
        original = json.loads((self.root / "tmp/worker-admission.json").read_text())
        (self.root / "overmind-calls").unlink(missing_ok=True)
        self.finish(self.updater())
        current = json.loads((self.root / "tmp/worker-admission.json").read_text())
        self.assertEqual(current["generation"], original["generation"])
        self.assertEqual(current["phase"], "resumed")
        self.assertEqual((self.root / "git-calls").read_text().splitlines(), ["rev-parse HEAD"])
        self.assertTrue(all(command == "status" for command in (self.root / "overmind-calls").read_text().splitlines()))
        self.assertFalse((self.root / "setup-ran").exists())

    def tearDown(self):
        for process in self.scripts + self.workers:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        self.temporary.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
