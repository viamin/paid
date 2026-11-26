#!/usr/bin/env python3
"""Own a worker admission generation without lending lock FDs to services.

@spec TEMPORAL-ORCHESTRATION-021
Only the controller process holds these descriptors. A request is not an ACK.
After ACK, losing the caller leaves requests closed for explicit recovery.
"""

import fcntl
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import signal
import select
import stat
import sys
import time
import uuid


class AdmissionError(RuntimeError):
    """The complete worker cohort cannot be proved safe to replace."""


def read_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
            raise AdmissionError("invalid admission metadata file")
        value = json.loads(stream.read(65537))
    if not isinstance(value, dict):
        raise AdmissionError("invalid admission metadata object")
    return value


def write_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def process_start_ticks(pid):
    contents = (Path("/proc") / str(pid) / "stat").read_text()
    return int(contents[contents.rindex(")") + 2:].split()[19])


def process_identity(pid):
    directory = Path("/proc") / str(pid)
    start_ticks = process_start_ticks(pid)
    arguments = (directory / "cmdline").read_bytes().split(b"\0")
    workspace = (directory / "cwd").resolve(strict=True)
    worker_script = workspace / "bin/temporal_worker"
    scripts = [Path(os.fsdecode(value)) for value in arguments if value]
    is_worker = any(
        str(value) == "bin/temporal_worker" or value == worker_script
        for value in scripts
    )
    if not is_worker:
        raise AdmissionError("process is not the expected Temporal worker")
    if process_start_ticks(pid) != start_ticks:
        raise AdmissionError("worker process changed during observation")
    return {"start_ticks": start_ticks, "workspace": str(workspace)}


def supervisor_cohort(workspace, supervisors, processes):
    """Resolve both logical roles through the actual supervisor process tree.

    The caller supplies a fresh bounded process snapshot, not readiness claims.
    Readiness must subsequently match this result before admission can ACK.
    """
    if set(supervisors) != {"poll", "agent"}:
        raise AdmissionError("both supervisor roles are required")
    for identity in supervisors.values():
        current = processes.get(identity.get("pid"))
        if current is None or current["start_ticks"] != identity.get("start_ticks"):
            raise AdmissionError("supervisor process changed")

    def descends_from(pid, ancestor):
        visited = set()
        while pid in processes and pid not in visited:
            if pid == ancestor:
                return True
            visited.add(pid)
            pid = processes[pid]["parent"]
        return False

    workers = {pid: value for pid, value in processes.items() if value.get("worker_roles")}
    result = {}
    for role, supervisor in supervisors.items():
        descendants = {pid: value for pid, value in workers.items()
                       if descends_from(pid, supervisor["pid"])}
        if any(value.get("workspace") != workspace for value in descendants.values()):
            raise AdmissionError("supervisor worker workspace is unknown")
        candidates = {pid: value for pid, value in descendants.items() if role in value["worker_roles"]}
        if len(candidates) != 1:
            raise AdmissionError("supervisor role does not resolve to exactly one worker")
        pid, value = next(iter(candidates.items()))
        result[role] = {"pid": pid, "start_ticks": value["start_ticks"]}
    covered = {identity["pid"] for identity in result.values()}
    if any(value.get("workspace") == workspace and pid not in covered for pid, value in workers.items()):
        raise AdmissionError("workspace has an uncovered Temporal worker")
    return result


class Drain:
    """One serialized, persistent generation for every affected worker role."""

    def __init__(self, workspace, roles, target_revision, expected_processes, *, identity_reader=process_identity,
                 original_process_reader=process_start_ticks, stopped=False, gate_paths=None):
        self.workspace = str(Path(workspace).resolve(strict=True))
        self.roles = self.normalize_roles(roles)
        self.original_roles = dict(self.roles)
        self.gate_paths = tuple(sorted({self.normalize_path(path) for path in
                                       (self.roles.values() if gate_paths is None else gate_paths)}))
        if not 1 <= len(self.gate_paths) <= 3 or not set(self.roles.values()).issubset(self.gate_paths):
            raise AdmissionError("launch-path gate coverage is incomplete")
        if not re.fullmatch(r"[0-9a-f]{40}", target_revision):
            raise AdmissionError("target revision is unknown")
        self.target_revision = target_revision
        if stopped and expected_processes != {}:
            raise AdmissionError("stopped recovery requires an explicitly empty cohort")
        self.expected_processes = {} if stopped else self.validate_processes(expected_processes)
        self.stopped = stopped
        self.completed = False
        self.target_snapshots = {}
        self.target_paths = {}
        self.update_phase = "draining"
        self.identity_reader = identity_reader
        self.original_process_reader = original_process_reader
        self.directory = Path(self.workspace) / "tmp"
        self.journal = self.directory / "worker-admission.json"
        self.generation = str(uuid.uuid4())
        self.controller = None
        self.locks = []
        self.requests = []
        self.snapshots = {}
        self.acknowledged = False
        self.preserve_requests = False
        self.parent_pid = os.getppid()

    @staticmethod
    def normalize_path(path):
        path = Path(path).absolute()
        return path.parent.resolve(strict=True) / path.name

    @classmethod
    def normalize_roles(cls, roles):
        if not isinstance(roles, dict) or set(roles) != {"agent", "poll"}:
            raise AdmissionError("both worker roles are required")
        return {role: cls.normalize_path(path) for role, path in roles.items()}

    def request_paths(self):
        return [Path(str(path) + ".admission.request") for path in self.gate_paths]

    def validate_processes(self, processes):
        if not isinstance(processes, dict) or set(processes) != set(self.roles):
            raise AdmissionError("complete supervisor-owned process cohort is required")
        for identity in processes.values():
            if not isinstance(identity, dict) or set(identity) != {"pid", "start_ticks"} or any(type(value) is not int or value <= 0 for value in identity.values()):
                raise AdmissionError("invalid supervisor-owned process identity")
        return {role: dict(identity) for role, identity in processes.items()}

    def snapshot(self, role, expected_processes=None, roles=None):
        marker = read_json((roles or self.roles)[role])
        admission = marker.get("admission", {})
        if not isinstance(admission, dict) or type(admission.get("protocol")) is not int or admission.get("protocol") != 1 or admission.get("scope") != "paid-workflow-and-remote-activity":
            raise AdmissionError("worker lacks supported admission capability")
        if admission.get("workspace") != self.workspace:
            raise AdmissionError("worker belongs to another workspace")
        if not re.fullmatch(r"[0-9a-f]{40}", str(admission.get("revision", ""))):
            raise AdmissionError("worker revision is unknown")
        if marker.get("revision") != admission["revision"] or marker.get("pid") != admission.get("pid"):
            raise AdmissionError("worker boot metadata disagrees")
        try:
            uuid.UUID(admission["boot_id"])
            pid = admission["pid"]
            if type(pid) is not int or pid <= 0:
                raise ValueError("invalid PID")
            actual = self.identity_reader(pid)
            profile = admission["profiles"][role]
        except (KeyError, TypeError, ValueError, OSError) as error:
            raise AdmissionError("worker identity or role is unknown") from error
        fields = {"activity_slots", "activity_task_polls", "local_activity_slots", "workflow_slots", "workflow_task_polls"}
        if set(profile) != fields or any(type(value) is not int or value <= 0 for value in profile.values()):
            raise AdmissionError("worker profile is incomplete")
        if actual != {"start_ticks": admission.get("process_start_ticks"), "workspace": self.workspace}:
            raise AdmissionError("worker process was replaced")
        expected = (expected_processes or self.expected_processes)[role]
        if expected != {"pid": pid, "start_ticks": admission["process_start_ticks"]}:
            raise AdmissionError("readiness does not cover the supervisor-owned worker")
        return admission

    def record(self, phase):
        write_json(self.journal, {
            "protocol": 1, "generation": self.generation, "phase": phase,
            "workspace": self.workspace, "roles": {key: str(value) for key, value in self.original_roles.items()},
            "gates": [str(path) for path in self.gate_paths],
            "target_roles": {key: str(value) for key, value in self.target_paths.items()},
            "snapshots": self.snapshots, "target_revision": self.target_revision,
            "expected_processes": self.expected_processes, "update_phase": self.update_phase,
            "target_snapshots": self.target_snapshots,
        })

    def serialize(self):
        self.directory.mkdir(exist_ok=True)
        descriptor = os.open(self.directory / "worker-admission.controller.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise AdmissionError("invalid controller lock inode")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(descriptor)
            raise
        self.controller = descriptor

    def publish_requests(self):
        paths = self.request_paths()
        for path in paths:
            if path in self.requests:
                continue
            temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
            try:
                write_json(temporary, {"protocol": 1, "generation": self.generation, "workspace": self.workspace})
                os.link(temporary, path, follow_symlinks=False)
                self.requests.append(path)
            finally:
                temporary.unlink(missing_ok=True)

    def acquire_locks(self, deadline):
        inodes = set()
        for path in (Path(str(value) + ".admission.lock") for value in self.gate_paths):
            descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            self.locks.append(descriptor)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise AdmissionError("invalid admission lock inode")
            inode = (info.st_dev, info.st_ino)
            if inode in inodes:
                self.locks.pop()
                os.close(descriptor)
                continue
            inodes.add(inode)
            while True:
                self.check_deadline(deadline)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))

    def acquire(self, timeout):
        if self.stopped:
            raise AdmissionError("an empty cohort is only valid for explicit recovery")
        if not 0 < timeout <= 120:
            raise AdmissionError("invalid existing drain budget")
        deadline = time.monotonic() + timeout
        try:
            self.serialize()
            if self.journal.exists() and read_json(self.journal).get("phase") not in ("aborted", "resumed"):
                raise AdmissionError("previous generation requires explicit recovery")
            self.snapshots = {role: self.snapshot(role) for role in self.roles}
            self.record("requested")
            self.publish_requests()
            self.acquire_locks(deadline)
            self.verify_old_cohort()
            self.check_deadline(deadline)
            self.record("acknowledged")
            self.check_deadline(deadline)
            self.acknowledged = True
            return {"generation": self.generation, "roles": sorted(self.roles), "acknowledged": True}
        except BaseException:
            self.close()
            raise

    def recover(self, timeout):
        if not 0 < timeout <= 120:
            raise AdmissionError("invalid existing drain budget")
        deadline = time.monotonic() + timeout
        try:
            self.serialize()
            # Malformed recovery metadata must never reopen a closed generation.
            self.preserve_requests = True
            previous = read_json(self.journal)
            if previous.get("workspace") != self.workspace or previous.get("target_revision") != self.target_revision:
                raise AdmissionError("recovery workspace, cohort or target disagrees")
            original_roles = self.normalize_roles(previous.get("roles"))
            previous_gates = {self.normalize_path(path) for path in previous.get("gates", original_roles.values())}
            if previous_gates != set(self.gate_paths) or not set(original_roles.values()).issubset(previous_gates):
                raise AdmissionError("recorded launch-path gate coverage disagrees")
            self.original_roles = original_roles
            if previous.get("phase") not in ("requested", "acknowledged", "resumed"):
                raise AdmissionError("generation does not require recovery")
            uuid.UUID(previous["generation"])
            self.generation = previous["generation"]
            self.snapshots = previous["snapshots"]
            if not isinstance(self.snapshots, dict) or set(self.snapshots) != set(self.roles):
                raise AdmissionError("recovery snapshots are incomplete")
            self.update_phase = previous.get("update_phase", "draining")
            if self.update_phase not in ("draining", "stopping", "stopped", "setup", "starting", "complete"):
                raise AdmissionError("recorded update phase is unknown")
            self.target_snapshots = previous.get("target_snapshots", {})
            if previous["phase"] == "resumed":
                self.completed = True
                self.target_paths = self.normalize_roles(previous.get("target_roles") or previous["roles"])
                if self.roles != self.target_paths:
                    raise AdmissionError("completed target launch paths disagree")
                self.verify_completed()
                self.check_deadline(deadline)
                return {"generation": self.generation, "roles": sorted(self.roles), "completed": True,
                        "cohort": "target", "next_action": "already-complete", "update_phase": "complete"}
            if self.stopped:
                if previous["phase"] != "acknowledged":
                    raise AdmissionError("stopped recovery requires a previously complete acknowledgement")
                self.verify_original_instances_gone(self.roles)
            current = {} if self.stopped else {role: self.snapshot(role) for role in self.roles}
            unchanged = current == self.snapshots
            target_roles = {
                role for role, value in current.items()
                if value["revision"] == self.target_revision and value["boot_id"] != self.snapshots[role]["boot_id"]
                and (value["pid"], value["process_start_ticks"]) != (self.snapshots[role]["pid"], self.snapshots[role]["process_start_ticks"])
            }
            known = all(value == self.snapshots[role] or role in target_roles for role, value in current.items())
            if not self.stopped and not unchanged and not (previous["phase"] == "acknowledged" and known):
                raise AdmissionError("mixed or unknown worker boots require investigation before stop")
            self.verify_original_instances_gone(target_roles)
            if self.update_phase in ("stopped", "setup", "starting"):
                self.verify_original_instances_gone(self.roles)
            elif self.update_phase == "complete":
                raise AdmissionError("active generation cannot claim completed phase")
            for path in self.request_paths():
                try:
                    value = read_json(path)
                except FileNotFoundError:
                    if previous["phase"] == "requested" and unchanged:
                        continue
                    raise AdmissionError("acknowledged request is missing; investigate before stop")
                if value.get("generation") != self.generation or value.get("workspace") != self.workspace:
                    raise AdmissionError("recovery request ownership disagrees")
                self.requests.append(path)
            self.publish_requests()
            self.acquire_locks(deadline)
            if self.stopped:
                self.verify_original_instances_gone(self.roles)
            elif any(self.snapshot(role) != current[role] for role in self.roles):
                raise AdmissionError("worker changed during recovery")
            self.check_deadline(deadline)
            self.record("acknowledged")
            self.check_deadline(deadline)
            self.acknowledged = True
            cohort = "stopped" if self.stopped else "unchanged" if unchanged else "target" if len(target_roles) == len(self.roles) else "mixed"
            stopped_action = "start-target" if self.update_phase == "starting" else "setup-and-start-target"
            actions = {"stopped": stopped_action, "unchanged": "stop-original-cohort",
                       "mixed": "finish-target-replacement", "target": "verify-and-resume-target"}
            return {"generation": self.generation, "roles": sorted(self.roles), "acknowledged": True,
                    "cohort": cohort, "next_action": actions[cohort], "update_phase": self.update_phase}
        except BaseException:
            self.close()
            raise

    def check_deadline(self, deadline):
        if os.getppid() != self.parent_pid:
            raise AdmissionError("controller caller exited before complete acknowledgement")
        if time.monotonic() >= deadline:
            raise AdmissionError("complete acknowledgement exceeded the existing drain budget")

    def verify_old_cohort(self):
        if self.stopped or self.completed:
            raise AdmissionError("there is no unchanged live cohort to abort")
        if any(self.snapshot(role) != self.snapshots[role] for role in self.roles):
            raise AdmissionError("worker identity changed while draining")

    def checkpoint(self, phase):
        phases = ("draining", "stopping", "stopped", "setup", "starting")
        if not self.acknowledged or phase not in phases or self.update_phase not in phases:
            raise AdmissionError("invalid acknowledged update checkpoint")
        if phases.index(phase) < phases.index(self.update_phase):
            raise AdmissionError("update checkpoint cannot move backwards")
        if phase in ("stopped", "setup", "starting"):
            self.verify_original_instances_gone(self.roles)
        self.update_phase = phase
        self.record("acknowledged")

    def verify_completed(self):
        if self.stopped or set(self.target_snapshots) != set(self.roles):
            raise AdmissionError("completed target cohort is unknown")
        current = {role: self.snapshot(role) for role in self.roles}
        if current != self.target_snapshots:
            raise AdmissionError("completed target boot changed")
        self.verify_original_instances_gone(self.roles)
        if any(os.path.lexists(path) for path in self.request_paths()):
            raise AdmissionError("another admission request requires investigation")

    def remove_requests(self):
        for path in self.requests:
            try:
                value = read_json(path)
            except FileNotFoundError:
                continue
            if value.get("generation") != self.generation or value.get("workspace") != self.workspace:
                raise AdmissionError("request generation ownership changed")
        for path in self.requests:
            path.unlink(missing_ok=True)
        self.requests = []

    def abort(self):
        if not self.acknowledged or self.controller is None or self.update_phase != "draining":
            raise AdmissionError("only the serialized pre-stop owner can abort")
        self.verify_old_cohort()
        self.remove_requests()
        self.record("aborted")
        self.acknowledged = False
        self.preserve_requests = False
        self.close()

    def verify_original_instances_gone(self, roles):
        observed = set()
        for role in roles:
            original = self.snapshots[role]
            identity = (original["pid"], original["process_start_ticks"])
            if identity in observed:
                continue
            observed.add(identity)
            try:
                current_ticks = self.original_process_reader(original["pid"])
            except (FileNotFoundError, ProcessLookupError):
                continue
            except (OSError, ValueError, IndexError):
                raise AdmissionError("original worker process visibility is unknown") from None
            if current_ticks == original["process_start_ticks"]:
                raise AdmissionError("original worker process instance remains alive")

    def resume(self, revision, expected_processes, roles=None):
        target_paths = self.roles if roles is None else self.normalize_roles(roles)
        if not set(target_paths.values()).issubset(self.gate_paths):
            raise AdmissionError("target launch paths were not fenced")
        if self.completed:
            expected_processes = self.validate_processes(expected_processes)
            if revision != self.target_revision or expected_processes != self.expected_processes or target_paths != self.target_paths:
                raise AdmissionError("completed target cohort disagrees")
            if self.controller is None:
                self.serialize()
            try:
                previous = read_json(self.journal)
                if previous.get("generation") != self.generation or previous.get("phase") != "resumed":
                    raise AdmissionError("completed generation changed")
                self.verify_completed()
            finally:
                self.close()
            return
        if not self.acknowledged or revision != self.target_revision:
            raise AdmissionError("no complete acknowledgement")
        expected_processes = self.validate_processes(expected_processes)
        target = {}
        for role in self.roles:
            current = self.snapshot(role, expected_processes, roles=target_paths)
            target[role] = current
            old = self.snapshots[role]
            if current["revision"] != revision or current["boot_id"] == old["boot_id"] or (current["pid"], current["process_start_ticks"]) == (old["pid"], old["process_start_ticks"]):
                raise AdmissionError("target worker boot is not verified")
        self.verify_original_instances_gone(self.roles)
        self.expected_processes = expected_processes
        self.roles = dict(target_paths)
        self.target_paths = dict(target_paths)
        self.target_snapshots = target
        self.update_phase = "complete"
        self.remove_requests()
        self.record("resumed")
        self.completed = True
        self.stopped = False
        self.acknowledged = False
        self.preserve_requests = False
        self.close()

    def close(self):
        if self.controller is None:
            return
        try:
            if not self.acknowledged and not self.preserve_requests and not self.completed:
                # A link syscall can finish before its caller observes success.
                # Discover our complete generation while still serialized; never
                # infer ownership merely from a request path's existence.
                for path in self.request_paths():
                    try:
                        value = read_json(path)
                    except (FileNotFoundError, ValueError, OSError):
                        continue
                    if value.get("generation") == self.generation and value.get("workspace") == self.workspace and path not in self.requests:
                        self.requests.append(path)
                if self.requests:
                    self.remove_requests()
                    self.record("aborted")
        except BaseException:
            self.preserve_requests = True
            raise
        finally:
            for descriptor in self.locks:
                os.close(descriptor)
            self.locks = []
            if self.controller is not None:
                os.close(self.controller)
                self.controller = None


def read_command(parent_pid):
    contents = bytearray()
    while len(contents) <= 1024:
        if os.getppid() != parent_pid:
            raise AdmissionError("controller caller exited; admission remains closed for recovery")
        readable, _writable, _exceptional = select.select([sys.stdin.fileno()], [], [], 0.1)
        if not readable:
            continue
        chunk = os.read(sys.stdin.fileno(), 1025 - len(contents))
        if not chunk:
            raise AdmissionError("caller outcome unknown; admission remains closed")
        contents.extend(chunk)
        if b"\n" in contents:
            return contents.decode("ascii")
    raise AdmissionError("invalid controller command; admission remains closed")


def finish_handshake(parent_pid):
    """Keep final stdout readable briefly without retaining admission locks."""
    deadline = time.monotonic() + 5
    while os.getppid() == parent_pid and time.monotonic() < deadline:
        readable, _writable, _exceptional = select.select([sys.stdin.fileno()], [], [],
                                                        min(0.1, max(0, deadline - time.monotonic())))
        if readable:
            # Completion is already durable. EOF, close or malformed input all
            # end this transport-only wait; none can change admission state.
            os.read(sys.stdin.fileno(), 1025)
            return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--role", action="append", required=True, help="agent=PATH or poll=PATH")
    parser.add_argument("--process", action="append", default=[], help="supervisor-discovered agent=PID:START_TICKS or poll=PID:START_TICKS")
    parser.add_argument("--gate", action="append", help="old or target launch path to fence before acknowledgement")
    parser.add_argument("--target-revision", required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--mode", choices=("drain", "recover"), default="drain")
    parser.add_argument("--stopped", action="store_true", help="recover a cohort whose original instances are proved gone")
    parser.add_argument("--finish-handshake", action="store_true",
                        help="wait at most five seconds for caller close after final status")
    arguments = parser.parse_args()
    drain = None
    recovery = [sys.executable, str(Path(__file__).resolve()), "--workspace", arguments.workspace,
                "--target-revision", arguments.target_revision, "--timeout", str(arguments.timeout), "--mode", "recover"]
    if arguments.stopped:
        recovery.append("--stopped")
    for gate in arguments.gate or []:
        recovery.extend(["--gate", gate])
    for role in arguments.role:
        recovery.extend(["--role", role])
    for process in arguments.process:
        recovery.extend(["--process", process])

    def interrupted(_signal, _frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise AdmissionError("controller interrupted; worker stop is not authorized")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        roles = {}
        for entry in arguments.role:
            role, separator, path = entry.partition("=")
            if not separator or role in roles:
                raise AdmissionError("duplicate or invalid role argument")
            roles[role] = path
        processes = {}
        for entry in arguments.process:
            role, separator, identity = entry.partition("=")
            if not separator or role in processes:
                raise AdmissionError("duplicate or invalid supervisor process argument")
            pid, start_ticks = identity.split(":")
            processes[role] = {"pid": int(pid), "start_ticks": int(start_ticks)}
        drain = Drain(arguments.workspace, roles, arguments.target_revision, processes,
                      stopped=arguments.stopped, gate_paths=arguments.gate)
        acknowledgement = drain.recover(arguments.timeout) if arguments.mode == "recover" else drain.acquire(arguments.timeout)
        print(json.dumps({"status": "acknowledged", **acknowledgement}), flush=True)
        command = read_command(drain.parent_pid)
        while command != "abort\n":
            value = json.loads(command)
            if not isinstance(value, dict) or value.get("action") != "checkpoint":
                break
            drain.checkpoint(value.get("phase"))
            print(json.dumps({"status": "checkpoint", "phase": drain.update_phase}), flush=True)
            command = read_command(drain.parent_pid)
        if command == "abort\n":
            drain.abort()
            print(json.dumps({"status": "aborted"}), flush=True)
        else:
            value = json.loads(command)
            if not isinstance(value, dict) or value.get("action") != "resume":
                raise AdmissionError("caller outcome unknown; admission remains closed")
            drain.resume(arguments.target_revision, value.get("processes"), roles=value.get("roles"))
            print(json.dumps({"status": "resumed"}), flush=True)
        if arguments.finish_handshake:
            drain.close()
            finish_handshake(drain.parent_pid)
        return 0
    except (AdmissionError, OSError, ValueError, KeyError, TypeError) as error:
        if drain is not None:
            try:
                drain.close()
            except (AdmissionError, OSError, ValueError):
                drain.preserve_requests = True
        preserve = drain is not None and (drain.acknowledged or drain.preserve_requests)
        print(json.dumps({"status": "deferred", "reason": str(error) if isinstance(error, AdmissionError) else type(error).__name__,
                          "recovery_required": preserve, "recovery_command": shlex.join(recovery) if preserve else None}), flush=True)
        return 1
    finally:
        if drain is not None:
            drain.close()


if __name__ == "__main__":
    sys.exit(main())
