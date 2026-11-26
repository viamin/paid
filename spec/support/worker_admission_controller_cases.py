"""Isolated controller contracts; not SDK/server or operating adoption proof.

@spec TEMPORAL-ORCHESTRATION-021
"""

import fcntl
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import subprocess
import selectors
import signal
from unittest.mock import patch
import uuid

from worker_admission import AdmissionError, Drain, process_identity, read_json, write_json
import worker_admission


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.paths = {role: self.root / role for role in ("agent", "poll")}
        self.processes = {11: {"start_ticks": 101, "workspace": str(self.root)},
                          12: {"start_ticks": 102, "workspace": str(self.root)}}
        self.expected_processes = {"agent": {"pid": 11, "start_ticks": 101}, "poll": {"pid": 12, "start_ticks": 102}}
        self.drains = []
        self.permits = []
        for role, pid in zip(self.paths, self.processes):
            self.marker(role, pid)

    def start_ticks(self, pid):
        if pid not in self.processes:
            try:
                value = (Path("/proc") / str(pid) / "stat").read_text()
                return int(value[value.rindex(")") + 2:].split()[19])
            except FileNotFoundError:
                raise ProcessLookupError(pid) from None
        return self.processes[pid]["start_ticks"]

    def tearDown(self):
        for drain in self.drains:
            drain.close()
        for permit in self.permits:
            os.close(permit)
        self.temporary.cleanup()

    def marker(self, role, pid, revision="a" * 40, roles=None):
        profile = {key: 4 for key in ("activity_slots", "activity_task_polls", "local_activity_slots",
                                      "workflow_slots", "workflow_task_polls")}
        admission = {"protocol": 1, "scope": "paid-workflow-and-remote-activity", "pid": pid,
                     "process_start_ticks": self.processes[pid]["start_ticks"], "workspace": str(self.root),
                     "revision": revision, "boot_id": str(uuid.uuid4()),
                     "profiles": {value: profile for value in (roles or [role])}}
        write_json(self.paths[role], {"pid": pid, "revision": revision, "admission": admission})

    def drain(self):
        drain = Drain(self.root, self.paths, "b" * 40, self.expected_processes,
                      identity_reader=lambda pid: self.processes[pid], original_process_reader=self.start_ticks)
        self.drains.append(drain)
        return drain

    def reserve(self, role):
        descriptor = os.open(str(self.paths[role]) + ".admission.lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        self.permits.append(descriptor)
        return descriptor

    def release(self, descriptor):
        os.close(descriptor)
        self.permits.remove(descriptor)

    def replace(self, role, pid, revision="b" * 40):
        old_pid = self.expected_processes[role]["pid"]
        self.processes[pid] = {"start_ticks": pid + 200, "workspace": str(self.root)}
        self.expected_processes[role] = {"pid": pid, "start_ticks": pid + 200}
        self.marker(role, pid, revision=revision)
        if old_pid not in {value["pid"] for value in self.expected_processes.values()}:
            del self.processes[old_pid]

    def requests(self):
        return [Path(str(path) + ".admission.request") for path in set(self.paths.values())]

    def test_ack_waits_for_both_issued_permits_after_publishing_all_requests(self):
        permits = [self.reserve(role) for role in self.paths]
        drain = self.drain()
        results = []
        errors = []

        def acquire():
            try:
                results.append(drain.acquire(1))
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=acquire)
        thread.start()
        try:
            deadline = time.monotonic() + 0.5
            while not all(path.exists() for path in self.requests()) and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertTrue(all(path.exists() for path in self.requests()))
            self.assertEqual(results, [])
            self.release(permits[0])
            time.sleep(0.01)
            self.assertEqual(results, [])
            self.release(permits[1])
            thread.join(1)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
            self.assertTrue(results[0]["acknowledged"])
        finally:
            for descriptor in permits:
                if descriptor in self.permits:
                    self.release(descriptor)
            thread.join(1)

    def test_abort_reopens_unchanged_workers(self):
        drain = self.drain()
        drain.acquire(1)
        drain.abort()
        self.assertFalse(any(path.exists() for path in self.requests()))
        self.assertEqual(read_json(drain.journal)["phase"], "aborted")

    def test_timeout_removes_only_owned_requests_without_ack(self):
        self.reserve("poll")
        drain = self.drain()
        with self.assertRaises(AdmissionError):
            drain.acquire(0.05)
        self.assertFalse(drain.acknowledged)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_unsupported_legacy_worker_refuses_before_request(self):
        write_json(self.paths["poll"], {"pid": 12, "active_activities": 0})
        with self.assertRaises(AdmissionError):
            self.drain().acquire(1)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_both_mode_coalesces_one_inode_but_acknowledges_both_roles(self):
        self.paths["poll"] = self.paths["agent"]
        self.expected_processes["poll"] = dict(self.expected_processes["agent"])
        self.marker("agent", 11, roles=["agent", "poll"])
        drain = self.drain()
        acknowledgement = drain.acquire(1)
        self.assertEqual(acknowledgement["roles"], ["agent", "poll"])
        self.assertEqual(len(drain.locks), 1)
        self.assertEqual(len(drain.requests), 1)

    def test_other_generation_is_neither_overwritten_nor_removed(self):
        other = self.requests()[1]
        write_json(other, {"generation": "other", "workspace": str(self.root)})
        with self.assertRaises(FileExistsError):
            self.drain().acquire(1)
        self.assertEqual(read_json(other)["generation"], "other")
        self.assertFalse(self.requests()[0].exists())

    def test_replaced_process_refuses_even_when_pid_and_body_count_match(self):
        self.processes[12]["start_ticks"] = 999
        with self.assertRaises(AdmissionError):
            self.drain().acquire(1)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_close_after_ack_keeps_admission_closed_for_explicit_recovery(self):
        drain = self.drain()
        drain.acquire(1)
        drain.close()
        self.assertTrue(all(path.exists() for path in self.requests()))
        with self.assertRaises(AdmissionError):
            self.drain().acquire(1)

    def test_resume_requires_every_new_boot_at_target_revision(self):
        drain = self.drain()
        drain.acquire(1)
        self.replace("agent", 21)
        with self.assertRaises(AdmissionError):
            drain.resume("b" * 40, self.expected_processes)
        self.assertTrue(all(path.exists() for path in self.requests()))
        self.replace("poll", 22)
        drain.resume("b" * 40, self.expected_processes)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_abort_refuses_a_changed_worker_without_reopening_admission(self):
        drain = self.drain()
        drain.acquire(1)
        self.marker("poll", 12)
        with self.assertRaises(AdmissionError):
            drain.abort()
        self.assertTrue(all(path.exists() for path in self.requests()))

    def test_request_symlink_is_not_followed_or_deleted(self):
        request = self.requests()[1]
        target = self.root / "unrelated"
        target.write_text("unchanged")
        request.symlink_to(target)
        with self.assertRaises(FileExistsError):
            self.drain().acquire(1)
        self.assertTrue(request.is_symlink())
        self.assertEqual(target.read_text(), "unchanged")

    def test_controller_descriptors_cannot_be_inherited_by_restarted_services(self):
        drain = self.drain()
        drain.acquire(1)
        self.assertTrue(all(not os.get_inheritable(fd) for fd in [drain.controller, *drain.locks]))

    def test_recovery_reacquires_every_lock_before_acknowledging_unchanged_workers(self):
        original = self.drain()
        original.acquire(1)
        original.close()
        permit = self.reserve("poll")
        recovery = self.drain()
        with self.assertRaises(AdmissionError):
            recovery.recover(0.05)
        self.assertTrue(all(path.exists() for path in self.requests()))
        self.release(permit)
        recovery = self.drain()
        acknowledgement = recovery.recover(1)
        self.assertEqual(acknowledgement["generation"], original.generation)
        recovery.abort()
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_recovery_classifies_known_mixed_boots_before_replacing_remaining_roles(self):
        original = self.drain()
        original.acquire(1)
        original.close()
        self.replace("agent", 21)
        mixed = self.drain()
        self.assertEqual(mixed.recover(1)["cohort"], "mixed")
        with self.assertRaises(AdmissionError):
            mixed.abort()
        mixed.close()
        self.assertTrue(all(path.exists() for path in self.requests()))
        self.replace("poll", 22)
        recovery = self.drain()
        recovery.recover(1)
        recovery.resume("b" * 40, self.expected_processes)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_resume_refuses_when_an_original_worker_remains_alive(self):
        drain = self.drain()
        drain.acquire(1)
        self.replace("agent", 21)
        self.replace("poll", 22)
        self.processes[11] = {"start_ticks": 101, "workspace": str(self.root)}
        with self.assertRaises(AdmissionError):
            drain.resume("b" * 40, self.expected_processes)
        self.assertTrue(all(path.exists() for path in self.requests()))

    def test_target_recovery_refuses_a_retained_original_process(self):
        original = self.drain()
        original.acquire(1)
        original.close()
        self.replace("agent", 21)
        self.replace("poll", 22)
        self.processes[12] = {"start_ticks": 102, "workspace": str(self.root)}
        with self.assertRaises(AdmissionError):
            self.drain().recover(1)
        self.assertTrue(all(path.exists() for path in self.requests()))

    def test_unknown_original_pid_visibility_does_not_authorize_resume(self):
        drain = self.drain()
        drain.acquire(1)
        self.replace("agent", 21)
        self.replace("poll", 22)
        with patch.object(drain, "original_process_reader", side_effect=PermissionError):
            with self.assertRaises(AdmissionError):
                drain.resume("b" * 40, self.expected_processes)
        self.assertTrue(all(path.exists() for path in self.requests()))

    def test_reused_numeric_pid_does_not_preserve_the_original_process_instance(self):
        drain = self.drain()
        drain.acquire(1)
        self.replace("agent", 21)
        self.replace("poll", 22)
        self.processes[11] = {"start_ticks": 999, "workspace": str(self.root)}
        drain.resume("b" * 40, self.expected_processes)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_late_successful_lock_acquisition_cannot_ack_after_deadline(self):
        now = [0.0]
        original = fcntl.flock

        def delayed_lock(descriptor, operation):
            result = original(descriptor, operation)
            if os.readlink("/proc/self/fd/" + str(descriptor)).endswith("poll.admission.lock"):
                now[0] = 2.0
            return result

        with patch("worker_admission.time.monotonic", side_effect=lambda: now[0]):
            with patch("worker_admission.fcntl.flock", side_effect=delayed_lock):
                drain = self.drain()
                with self.assertRaises(AdmissionError):
                    drain.acquire(1)
        self.assertFalse(drain.acknowledged)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_parent_aliases_preserve_both_roles_without_double_locking(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.paths["poll"] = alias / "agent"
        self.expected_processes["poll"] = dict(self.expected_processes["agent"])
        self.marker("agent", 11, roles=["agent", "poll"])
        drain = self.drain()
        acknowledgement = drain.acquire(1)
        self.assertEqual(acknowledgement["roles"], ["agent", "poll"])
        self.assertEqual(len(drain.locks), 1)

    def test_hard_linked_admission_inodes_are_acquired_only_once(self):
        self.reserve("agent")
        self.release(self.permits[0])
        os.link(str(self.paths["agent"]) + ".admission.lock", str(self.paths["poll"]) + ".admission.lock")
        drain = self.drain()
        drain.acquire(1)
        self.assertEqual(len(drain.locks), 1)

    def test_interrupted_request_publication_recovers_only_its_completed_link(self):
        original = os.link

        def unknown_link_outcome(*args, **kwargs):
            original(*args, **kwargs)
            raise AdmissionError("publication caller interrupted")

        with patch("worker_admission.os.link", side_effect=unknown_link_outcome):
            with self.assertRaises(AdmissionError):
                self.drain().acquire(1)
        self.assertFalse(any(path.exists() for path in self.requests()))

    def test_recovery_finishes_a_partial_pre_ack_request_generation(self):
        original = self.drain()
        original.acquire(1)
        original.close()
        journal = read_json(original.journal)
        journal["phase"] = "requested"
        write_json(original.journal, journal)
        self.requests()[0].unlink()
        recovery = self.drain()
        recovery.recover(1)
        self.assertTrue(all(path.exists() for path in self.requests()))
        recovery.abort()
        self.assertFalse(any(path.exists() for path in self.requests()))

    def stopped_drain(self):
        drain = Drain(self.root, self.paths, "b" * 40, {}, stopped=True,
                      identity_reader=lambda pid: self.processes[pid], original_process_reader=self.start_ticks)
        self.drains.append(drain)
        return drain

    def test_stopped_recovery_requires_all_original_instances_gone_and_keeps_requests(self):
        original = self.drain()
        original.acquire(1)
        original.close()
        with self.assertRaises(AdmissionError):
            self.stopped_drain().recover(1)
        self.processes.clear()
        recovery = self.stopped_drain()
        acknowledgement = recovery.recover(1)
        self.assertEqual(acknowledgement["cohort"], "stopped")
        self.assertEqual(acknowledgement["next_action"], "setup-and-start-target")
        self.assertTrue(all(path.exists() for path in self.requests()))
        with self.assertRaises(AdmissionError):
            recovery.abort()

    def test_stopped_recovery_refuses_unknown_original_visibility(self):
        original = self.drain()
        original.acquire(1)
        original.close()
        recovery = self.stopped_drain()
        with patch.object(recovery, "original_process_reader", side_effect=PermissionError):
            with self.assertRaises(AdmissionError):
                recovery.recover(1)
        self.assertTrue(all(path.exists() for path in self.requests()))

    def test_phase_checkpoints_are_monotonic_and_stopped_requires_actual_exit(self):
        drain = self.drain()
        drain.acquire(1)
        drain.checkpoint("stopping")
        with self.assertRaises(AdmissionError):
            drain.checkpoint("stopped")
        self.processes.clear()
        drain.checkpoint("stopped")
        drain.checkpoint("setup")
        with self.assertRaises(AdmissionError):
            drain.checkpoint("stopping")
        self.assertEqual(read_json(drain.journal)["update_phase"], "setup")
        drain.close()
        recovery = self.stopped_drain()
        self.assertEqual(recovery.recover(1)["update_phase"], "setup")

    def test_completed_recovery_and_resume_do_not_republish_requests_or_restart(self):
        original = self.drain()
        original.acquire(1)
        self.replace("agent", 21)
        self.replace("poll", 22)
        original.resume("b" * 40, self.expected_processes)
        original.resume("b" * 40, self.expected_processes)
        recovery = self.drain()
        acknowledgement = recovery.recover(1)
        self.assertTrue(acknowledgement["completed"])
        self.assertEqual(acknowledgement["next_action"], "already-complete")
        recovery.resume("b" * 40, self.expected_processes)
        self.assertFalse(any(path.exists() for path in self.requests()))
        self.assertEqual(read_json(recovery.journal)["phase"], "resumed")

    def test_completed_recovery_refuses_new_generation_request_or_changed_target_boot(self):
        original = self.drain()
        original.acquire(1)
        self.replace("agent", 21)
        self.replace("poll", 22)
        original.resume("b" * 40, self.expected_processes)
        write_json(self.requests()[0], {"generation": str(uuid.uuid4()), "workspace": str(self.root)})
        with self.assertRaises(AdmissionError):
            self.drain().recover(1)
        self.requests()[0].unlink()
        self.marker("agent", 21, revision="b" * 40)
        with self.assertRaises(AdmissionError):
            self.drain().recover(1)

    def test_real_controller_eof_preserves_generation_and_explicit_recovery_can_abort(self):
        # These processes exercise only kernel process identity and pipe
        # ownership. They are not Temporal workers or SDK acceptance evidence.
        binary = self.root / "bin"
        binary.mkdir()
        (binary / "temporal_worker").write_text("$stdout.sync = true\nputs Process.pid\nsleep 30\n")
        workers = []
        controller = None
        try:
            for role in self.paths:
                process = subprocess.Popen(["ruby", "bin/temporal_worker"], cwd=self.root,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                workers.append(process)
                with selectors.DefaultSelector() as ready:
                    ready.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(ready.select(2), "identity fixture did not start")
                self.assertEqual(int(process.stdout.readline()), process.pid)
                self.processes[process.pid] = process_identity(process.pid)
                self.expected_processes[role] = {"pid": process.pid, "start_ticks": self.processes[process.pid]["start_ticks"]}
                self.marker(role, process.pid)
            command = [os.sys.executable, str(Path(worker_admission.__file__)), "--workspace", str(self.root),
                       "--target-revision", "b" * 40, "--timeout", "1"]
            for role, path in self.paths.items():
                command.extend(["--role", role + "=" + str(path)])
                expected = self.expected_processes[role]
                command.extend(["--process", role + "=" + str(expected["pid"]) + ":" + str(expected["start_ticks"])])
            controller = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, text=True)
            with selectors.DefaultSelector() as ready:
                ready.register(controller.stdout, selectors.EVENT_READ)
                self.assertTrue(ready.select(2), "controller did not acknowledge")
            acknowledgement = json.loads(controller.stdout.readline())
            self.assertEqual(acknowledgement["status"], "acknowledged")
            controller.stdin.close()
            controller.stdin = None
            output, errors = controller.communicate(timeout=2)
            self.assertEqual(controller.returncode, 1, errors)
            self.assertTrue(json.loads(output)["recovery_required"])
            self.assertTrue(all(path.exists() for path in self.requests()))
            recovery = subprocess.Popen(command + ["--mode", "recover", "--finish-handshake"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(json.loads(recovery.stdout.readline())["status"], "acknowledged")
                recovery.stdin.write("abort\n")
                recovery.stdin.flush()
                self.assertEqual(json.loads(recovery.stdout.readline())["status"], "aborted")
                self.assertIsNone(recovery.poll(), "completion must remain readable until caller closes")
                self.assertFalse(any(path.exists() for path in self.requests()))
                recovery.stdin.write("close\n")
                recovery.stdin.flush()
                output, errors = recovery.communicate(timeout=2)
                self.assertEqual(recovery.returncode, 0, errors + output)
            finally:
                if recovery.poll() is None:
                    recovery.terminate()
                    recovery.wait(timeout=2)
                for stream in (recovery.stdin, recovery.stdout, recovery.stderr):
                    if stream is not None:
                        stream.close()
            self.assertFalse(any(path.exists() for path in self.requests()))
        finally:
            for process in ([controller] if controller else []) + workers:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()

    def test_parent_exit_is_detected_even_when_a_grandchild_keeps_the_writer_open(self):
        self.paths["poll"] = self.paths["agent"]
        binary = self.root / "bin"
        binary.mkdir()
        (binary / "temporal_worker").write_text("$stdout.sync = true\nputs Process.pid\nsleep 30\n")
        worker = subprocess.Popen(["ruby", "bin/temporal_worker"], cwd=self.root,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        launcher = None
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(worker.stdout, selectors.EVENT_READ)
                self.assertTrue(ready.select(2))
            self.assertEqual(int(worker.stdout.readline()), worker.pid)
            self.processes[worker.pid] = process_identity(worker.pid)
            self.expected_processes = {role: {"pid": worker.pid, "start_ticks": self.processes[worker.pid]["start_ticks"]}
                                       for role in self.paths}
            self.marker("agent", worker.pid, roles=["agent", "poll"])
            command = [os.sys.executable, str(Path(worker_admission.__file__)), "--workspace", str(self.root),
                       "--target-revision", "b" * 40, "--timeout", "1"]
            for role, path in self.paths.items():
                command.extend(["--role", role + "=" + str(path)])
                expected = self.expected_processes[role]
                command.extend(["--process", role + "=" + str(expected["pid"]) + ":" + str(expected["start_ticks"])])
            output_path = self.root / "controller-output.jsonl"
            source = """
import json,os,pathlib,subprocess,sys,time
command=json.loads(sys.argv[1]); output=pathlib.Path(sys.argv[2])
reader,writer=os.pipe()
with output.open('w') as log:
 controller=subprocess.Popen(command,stdin=reader,stdout=log,stderr=log)
os.close(reader)
holder=subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)'],pass_fds=(writer,),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
os.close(writer)
deadline=time.monotonic()+2
while time.monotonic()<deadline:
 if output.read_text().splitlines():
  first=json.loads(output.read_text().splitlines()[0])
  if first.get('status')!='acknowledged':raise RuntimeError('no acknowledgement')
  print(json.dumps({'controller':controller.pid,'holder':holder.pid}),flush=True)
  os._exit(0)
 time.sleep(.01)
raise RuntimeError('controller never acknowledged')
"""
            launcher = subprocess.Popen([os.sys.executable, "-c", source, json.dumps(command), str(output_path)],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
            output, errors = launcher.communicate(timeout=3)
            self.assertEqual(launcher.returncode, 0, errors)
            identities = json.loads(output)
            deadline = time.monotonic() + 2
            while len(output_path.read_text().splitlines()) < 2 and time.monotonic() < deadline:
                time.sleep(0.01)
            observations = [json.loads(line) for line in output_path.read_text().splitlines()]
            self.assertEqual(len(observations), 2)
            self.assertEqual(observations[1]["status"], "deferred")
            self.assertIn("caller exited", observations[1]["reason"])
            self.assertTrue(observations[1]["recovery_required"])
            os.kill(identities["holder"], 0)
            recovery = self.drain()
            recovery.recover(1)
            recovery.abort()
            self.assertFalse(any(path.exists() for path in self.requests()))
        finally:
            if launcher is not None:
                try:
                    os.killpg(launcher.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                if launcher.poll() is None:
                    launcher.wait(timeout=2)
                launcher.stdout.close()
                launcher.stderr.close()
            if worker.poll() is None:
                worker.terminate()
                worker.wait(timeout=2)
            worker.stdout.close()
            worker.stderr.close()

    def test_another_genuine_workspace_worker_does_not_cover_the_supervisor_cohort(self):
        self.processes[13] = {"start_ticks": 103, "workspace": str(self.root)}
        self.marker("poll", 13)
        expected = {"agent": {"pid": 11, "start_ticks": 101}, "poll": {"pid": 12, "start_ticks": 102}}
        drain = Drain(self.root, self.paths, "b" * 40,
                      identity_reader=lambda pid: self.processes[pid], expected_processes=expected)
        self.drains.append(drain)
        with self.assertRaisesRegex(AdmissionError, "supervisor-owned"):
            drain.acquire(1)


class SupervisorCohortTest(unittest.TestCase):
    def setUp(self):
        self.workspace = "/private/workspace"
        self.supervisors = {"poll": {"pid": 10, "start_ticks": 100},
                            "agent": {"pid": 20, "start_ticks": 200}}
        self.processes = {
            10: {"parent": 1, "start_ticks": 100},
            11: {"parent": 10, "start_ticks": 101},
            12: {"parent": 11, "start_ticks": 102, "workspace": self.workspace, "worker_roles": ["poll"]},
            20: {"parent": 1, "start_ticks": 200},
            21: {"parent": 20, "start_ticks": 201, "workspace": self.workspace, "worker_roles": ["agent"]},
        }

    def cohort(self):
        return worker_admission.supervisor_cohort(self.workspace, self.supervisors, self.processes)

    def test_resolves_actual_workers_through_wrapper_descendants(self):
        self.assertEqual(self.cohort(), {"poll": {"pid": 12, "start_ticks": 102},
                                        "agent": {"pid": 21, "start_ticks": 201}})

    def test_refuses_genuine_same_workspace_orphan_outside_supervisor(self):
        self.processes[30] = {"parent": 1, "start_ticks": 300, "workspace": self.workspace,
                              "worker_roles": ["poll"]}
        with self.assertRaises(AdmissionError):
            self.cohort()

    def test_refuses_pid_reuse_or_missing_role_or_duplicate_worker(self):
        for change in ("reused", "missing", "duplicate"):
            with self.subTest(change=change):
                original = dict(self.processes)
                if change == "reused":
                    self.processes[10] = {"parent": 1, "start_ticks": 999}
                elif change == "missing":
                    del self.processes[12]
                else:
                    self.processes[13] = {"parent": 10, "start_ticks": 103,
                                          "workspace": self.workspace, "worker_roles": ["poll"]}
                with self.assertRaises(AdmissionError):
                    self.cohort()
                self.processes = original

    def test_coalesces_both_mode_under_one_supervisor_without_omitting_a_role(self):
        self.supervisors["agent"] = self.supervisors["poll"]
        del self.processes[21]
        self.processes[12]["worker_roles"] = ["poll", "agent"]
        self.assertEqual(self.cohort(), {role: {"pid": 12, "start_ticks": 102} for role in ("poll", "agent")})

    def test_refuses_wrong_mode_or_cross_workspace_descendant(self):
        for fields in ({"worker_roles": ["agent"]}, {"workspace": "/another/workspace"}):
            with self.subTest(fields=fields):
                original = dict(self.processes[12])
                self.processes[12].update(fields)
                with self.assertRaises(AdmissionError):
                    self.cohort()
                self.processes[12] = original


if __name__ == "__main__":
    unittest.main(verbosity=2)
