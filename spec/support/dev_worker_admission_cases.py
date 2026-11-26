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
        for name in ("worker_admission.py", "worker_admission_cohort.py", "dev_worker_admission.sh"):
            shutil.copyfile(source / "bin/lib" / name, self.root / "bin/lib" / name)
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
admission = {protocol: 1, scope: "paid-workflow-and-remote-activity", pid: pid, process_start_ticks: ticks, workspace: Dir.pwd, revision: revision, boot_id: SecureRandom.uuid, profiles: {mode => profile}}
path = File.join(ENV.fetch("TMPDIR"), "paid-worker-ready-temporal_worker-#{mode}")
File.write(path, JSON.generate({pid: pid, revision: revision, admission: admission}))
$stdout.sync = true
puts pid
sleep 30
''')
        (self.root / "bin/overmind").write_text('#!/bin/sh\ncat "$FIXTURE_STATUS"\n')
        (self.root / "bin/overmind").chmod(0o755)
        self.start_workers("a" * 40)

    def start_workers(self, revision):
        current = []
        for role in ("poll", "agent"):
            environment = dict(os.environ, TMPDIR=str(self.root / "tmp"), FIXTURE_REVISION=revision)
            worker = subprocess.Popen(["ruby", "bin/temporal_worker", "--mode=" + role], cwd=self.root,
                                      env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.workers.append(worker)
            current.append(worker)
            self.assertEqual(int(worker.stdout.readline()), worker.pid)
        self.status.write_text("PROCESS PID STATUS\n" + "".join(
            "worker_" + role + " " + str(worker.pid) + " running\n"
            for role, worker in zip(("poll", "agent"), current)))
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
        self.assertEqual(len(self.requests()), 2)
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
        self.assertEqual(len(self.requests()), 2)
        for worker in old:
            worker.terminate()
            worker.wait(timeout=2)
        self.start_workers("b" * 40)
        self.assertEqual(len(self.requests()), 2)
        (self.root / "go").touch()
        self.finish(script)
        self.assertFalse(self.requests())
        journal = json.loads((self.root / "tmp/worker-admission.json").read_text())
        self.assertEqual(journal["phase"], "resumed")
        self.assertEqual(journal["update_phase"], "complete")

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
