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
                 original_process_reader=process_start_ticks):
        self.workspace = str(Path(workspace).resolve(strict=True))
        if sorted(roles) != ["agent", "poll"]:
            raise AdmissionError("both worker roles are required")
        self.roles = {
            role: Path(path).absolute().parent.resolve(strict=True) / Path(path).name
            for role, path in roles.items()
        }
        if not re.fullmatch(r"[0-9a-f]{40}", target_revision):
            raise AdmissionError("target revision is unknown")
        self.target_revision = target_revision
        self.expected_processes = self.validate_processes(expected_processes)
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

    def validate_processes(self, processes):
        if not isinstance(processes, dict) or set(processes) != set(self.roles):
            raise AdmissionError("complete supervisor-owned process cohort is required")
        for identity in processes.values():
            if not isinstance(identity, dict) or set(identity) != {"pid", "start_ticks"} or any(type(value) is not int or value <= 0 for value in identity.values()):
                raise AdmissionError("invalid supervisor-owned process identity")
        return {role: dict(identity) for role, identity in processes.items()}

    def snapshot(self, role, expected_processes=None):
        marker = read_json(self.roles[role])
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
            "workspace": self.workspace, "roles": {key: str(value) for key, value in self.roles.items()},
            "snapshots": self.snapshots, "target_revision": self.target_revision,
            "expected_processes": self.expected_processes,
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
        paths = sorted({Path(str(path) + ".admission.request") for path in self.roles.values()})
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
        for path in sorted({Path(str(value) + ".admission.lock") for value in self.roles.values()}):
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
            previous = read_json(self.journal)
            expected_roles = {key: str(value) for key, value in self.roles.items()}
            if previous.get("workspace") != self.workspace or previous.get("roles") != expected_roles or previous.get("target_revision") != self.target_revision:
                raise AdmissionError("recovery workspace, cohort or target disagrees")
            if previous.get("phase") not in ("requested", "acknowledged"):
                raise AdmissionError("generation does not require recovery")
            uuid.UUID(previous["generation"])
            self.generation = previous["generation"]
            self.snapshots = previous["snapshots"]
            self.preserve_requests = True
            current = {role: self.snapshot(role) for role in self.roles}
            unchanged = current == self.snapshots
            target_roles = {
                role for role, value in current.items()
                if value["revision"] == self.target_revision and value["boot_id"] != self.snapshots[role]["boot_id"]
                and (value["pid"], value["process_start_ticks"]) != (self.snapshots[role]["pid"], self.snapshots[role]["process_start_ticks"])
            }
            known = all(value == self.snapshots[role] or role in target_roles for role, value in current.items())
            if not unchanged and not (previous["phase"] == "acknowledged" and known):
                raise AdmissionError("mixed or unknown worker boots require investigation before stop")
            self.verify_original_instances_gone(target_roles)
            for path in sorted({Path(str(value) + ".admission.request") for value in self.roles.values()}):
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
            if any(self.snapshot(role) != current[role] for role in self.roles):
                raise AdmissionError("worker changed during recovery")
            self.check_deadline(deadline)
            self.record("acknowledged")
            self.check_deadline(deadline)
            self.acknowledged = True
            return {"generation": self.generation, "roles": sorted(self.roles), "acknowledged": True,
                    "cohort": "unchanged" if unchanged else "target" if len(target_roles) == len(self.roles) else "mixed"}
        except BaseException:
            self.close()
            raise

    def check_deadline(self, deadline):
        if os.getppid() != self.parent_pid:
            raise AdmissionError("controller caller exited before complete acknowledgement")
        if time.monotonic() >= deadline:
            raise AdmissionError("complete acknowledgement exceeded the existing drain budget")

    def verify_old_cohort(self):
        if any(self.snapshot(role) != self.snapshots[role] for role in self.roles):
            raise AdmissionError("worker identity changed while draining")

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

    def resume(self, revision, expected_processes):
        if not self.acknowledged or revision != self.target_revision:
            raise AdmissionError("no complete acknowledgement")
        expected_processes = self.validate_processes(expected_processes)
        for role in self.roles:
            current = self.snapshot(role, expected_processes)
            old = self.snapshots[role]
            if current["revision"] != revision or current["boot_id"] == old["boot_id"] or (current["pid"], current["process_start_ticks"]) == (old["pid"], old["process_start_ticks"]):
                raise AdmissionError("target worker boot is not verified")
        self.verify_original_instances_gone(self.roles)
        self.remove_requests()
        self.record("resumed")
        self.acknowledged = False
        self.preserve_requests = False
        self.close()

    def close(self):
        if self.controller is None:
            return
        try:
            if not self.acknowledged and not self.preserve_requests:
                # A link syscall can finish before its caller observes success.
                # Discover our complete generation while still serialized; never
                # infer ownership merely from a request path's existence.
                for path in {Path(str(value) + ".admission.request") for value in self.roles.values()}:
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--role", action="append", required=True, help="agent=PATH or poll=PATH")
    parser.add_argument("--process", action="append", required=True, help="supervisor-discovered agent=PID:START_TICKS or poll=PID:START_TICKS")
    parser.add_argument("--target-revision", required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--mode", choices=("drain", "recover"), default="drain")
    arguments = parser.parse_args()
    drain = None
    recovery = [sys.executable, str(Path(__file__).resolve()), "--workspace", arguments.workspace,
                "--target-revision", arguments.target_revision, "--timeout", str(arguments.timeout), "--mode", "recover"]
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
        drain = Drain(arguments.workspace, roles, arguments.target_revision, processes)
        acknowledgement = drain.recover(arguments.timeout) if arguments.mode == "recover" else drain.acquire(arguments.timeout)
        print(json.dumps({"status": "acknowledged", **acknowledgement}), flush=True)
        command = read_command(drain.parent_pid)
        if command == "abort\n":
            drain.abort()
            print(json.dumps({"status": "aborted"}), flush=True)
        else:
            value = json.loads(command)
            if not isinstance(value, dict) or value.get("action") != "resume":
                raise AdmissionError("caller outcome unknown; admission remains closed")
            drain.resume(arguments.target_revision, value.get("processes"))
            print(json.dumps({"status": "resumed"}), flush=True)
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
