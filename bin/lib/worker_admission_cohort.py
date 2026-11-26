"""Supervisor identity checks and verified controller cleanup.

@spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
"""

import argparse
import json
from pathlib import Path
import re
import os
import select
import signal
import sys
import time

from worker_admission import AdmissionError, Drain, process_start_ticks, read_json, supervisor_cohort


def bounded_bytes(path, limit=131072):
    with path.open("rb") as stream:
        value = stream.read(limit + 1)
    if len(value) > limit:
        raise AdmissionError("process metadata exceeds its observation bound")
    return value


def process_record(proc_root, pid):
    directory = proc_root / str(pid)
    value = bounded_bytes(directory / "stat", 4096).decode()
    fields = value[value.rindex(")") + 2:].split()
    record = {"parent": int(fields[1]), "start_ticks": int(fields[19])}
    arguments = [value.decode() for value in bounded_bytes(directory / "cmdline").split(b"\0") if value]
    candidates = [index for index, value in enumerate(arguments)
                  if value in ("bin/temporal_worker", "./bin/temporal_worker") or value.endswith("/bin/temporal_worker")]
    if not candidates:
        return record
    if len(candidates) != 1:
        raise AdmissionError("ambiguous worker process arguments")
    index = candidates[0]
    workspace = (directory / "cwd").resolve(strict=True)
    script = Path(arguments[index])
    if not script.is_absolute():
        script = workspace / script
    if script.resolve() != workspace / "bin/temporal_worker":
        raise AdmissionError("worker script does not belong to its workspace")
    options = arguments[index + 1:]
    if options and (len(options) != 1 or not options[0].startswith("--mode=")):
        raise AdmissionError("unknown worker launch arguments")
    environment = bounded_bytes(directory / "environ").split(b"\0")
    modes = [value[len(b"TEMPORAL_WORKER_MODE="):].decode() for value in environment
             if value.startswith(b"TEMPORAL_WORKER_MODE=")]
    if len(modes) > 1:
        raise AdmissionError("ambiguous worker launch environment")
    configured = modes[0] if modes else None
    mode = options[0][len("--mode="):] if options else configured or "both"
    if mode not in ("poll", "agent", "both") or (options and configured is not None and configured != mode):
        raise AdmissionError("worker launch mode disagrees")
    record.update(workspace=str(workspace), worker_roles=["agent", "poll"] if mode == "both" else [mode])
    return record


def process_snapshot(proc_root, deadline):
    result = {}
    for path in proc_root.iterdir():
        if not re.fullmatch(r"[1-9][0-9]*", path.name):
            continue
        if time.monotonic() >= deadline or len(result) >= 65536:
            raise AdmissionError("process observation exceeded its finite bound")
        try:
            result[int(path.name)] = process_record(proc_root, int(path.name))
        except (FileNotFoundError, ProcessLookupError):
            # Exited processes are absent from this snapshot. Named supervisor
            # and worker identities are independently rechecked before return.
            continue
    return result


def supervisor_processes(status, snapshot):
    if len(status.encode()) > 65536:
        raise AdmissionError("supervisor status exceeds its observation bound")
    lines = status.splitlines()
    if not lines or lines[0].split() != ["PROCESS", "PID", "STATUS"]:
        raise AdmissionError("unknown supervisor status format")
    rows = {}
    for line in lines[1:]:
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 3 or not fields[1].isdigit() or int(fields[1]) <= 0 or fields[2] not in ("running", "dead") or fields[0] in rows:
            raise AdmissionError("unknown supervisor process row")
        rows[fields[0]] = fields
    result = {}
    for role in ("poll", "agent"):
        row = rows.get("worker_" + role)
        if row is None:
            continue
        pid = int(row[1])
        if row[2] != "running" or pid not in snapshot:
            raise AdmissionError("supervisor worker process is not live")
        result[role] = {"pid": pid, "start_ticks": snapshot[pid]["start_ticks"]}
    if len(result) == 1:
        # A single recognized supervisor entry can cover both roles only if
        # its actual descendant is a both-mode worker. supervisor_cohort
        # verifies that condition rather than trusting the row's name.
        identity = next(iter(result.values()))
        result = {role: dict(identity) for role in ("poll", "agent")}
    if set(result) != {"poll", "agent"}:
        raise AdmissionError("complete supervisor worker cohort is unavailable")
    return result


def discover_cohort(workspace, status, *, proc_root=Path("/proc")):
    workspace = str(Path(workspace).resolve(strict=True))
    deadline = time.monotonic() + 5
    snapshot = process_snapshot(proc_root, deadline)
    supervisors = supervisor_processes(status, snapshot)
    expected = supervisor_cohort(workspace, supervisors, snapshot)
    # A PID can exit or be reused while /proc is scanned. A second complete
    # snapshot must resolve the same cohort and supervisor start identities.
    current = process_snapshot(proc_root, deadline)
    if supervisor_processes(status, current) != supervisors or supervisor_cohort(workspace, supervisors, current) != expected:
        raise AdmissionError("supervisor cohort changed during observation")
    return expected


def controller_identity(pid, parent, workspace):
    directory = Path("/proc") / str(pid)
    contents = bounded_bytes(directory / "stat", 4096).decode()
    fields = contents[contents.rindex(")") + 2:].split()
    identity = {"pid": pid, "parent": int(fields[1]), "start_ticks": int(fields[19])}
    if identity["parent"] != parent or str((directory / "cwd").resolve(strict=True)) != workspace:
        raise AdmissionError("controller child identity disagrees")
    return identity


def reap_controller(identity, workspace):
    if not isinstance(identity, dict) or set(identity) != {"pid", "parent", "start_ticks"}:
        raise AdmissionError("controller identity is incomplete")
    if any(type(value) is not int or value <= 0 for value in identity.values()):
        raise AdmissionError("controller identity is invalid")
    try:
        descriptor = os.pidfd_open(identity["pid"])
    except ProcessLookupError:
        return {"original_absent": True, "wait_safe": True}
    try:
        try:
            current = controller_identity(identity["pid"], identity["parent"], workspace)
        except (FileNotFoundError, ProcessLookupError):
            return {"original_absent": True, "wait_safe": True}
        except AdmissionError:
            return {"original_absent": True, "wait_safe": False}
        if current != identity:
            return {"original_absent": True, "wait_safe": False}
        # Every signal addresses this exact kernel process handle, even if its
        # numeric PID exits and is reused after the identity check.
        for timeout, stop_signal in ((5, signal.SIGTERM), (0.1, signal.SIGKILL), (1, None)):
            if select.select([descriptor], [], [], timeout)[0]:
                return {"original_absent": True, "wait_safe": True}
            if stop_signal is not None:
                try:
                    signal.pidfd_send_signal(descriptor, stop_signal)
                except ProcessLookupError:
                    return {"original_absent": True, "wait_safe": True}
        raise AdmissionError("controller exit remains unknown; admission requires recovery")
    finally:
        os.close(descriptor)


def original_cohort_gone(cohort):
    if not isinstance(cohort, dict) or set(cohort) != {"poll", "agent"}:
        raise AdmissionError("original process cohort is incomplete")
    for identity in cohort.values():
        if not isinstance(identity, dict) or set(identity) != {"pid", "start_ticks"}:
            raise AdmissionError("original process identity is incomplete")
        if any(type(value) is not int or value <= 0 for value in identity.values()):
            raise AdmissionError("original process identity is invalid")
        try:
            ticks = process_start_ticks(identity["pid"])
        except (FileNotFoundError, ProcessLookupError):
            continue
        if ticks == identity["start_ticks"]:
            raise AdmissionError("original worker process instance remains alive")


def readiness_paths(cohort, directory):
    if not isinstance(cohort, dict) or set(cohort) != {"poll", "agent"}:
        raise AdmissionError("complete role cohort is required")
    for identity in cohort.values():
        if not isinstance(identity, dict) or set(identity) != {"pid", "start_ticks"} or any(
                type(value) is not int or value <= 0 for value in identity.values()):
            raise AdmissionError("role identity is invalid")
    directory = Path(directory).resolve(strict=True)
    if any(ord(character) < 32 for character in str(directory)):
        raise AdmissionError("readiness directory contains control characters")
    if cohort["agent"] != cohort["poll"]:
        return {role: str(directory / f"paid-worker-ready-temporal_worker-{role}") for role in cohort}
    candidates = [directory / "paid-worker-ready-temporal_worker",
                  directory / "paid-worker-ready-temporal_worker-both"]
    present = [path for path in candidates if path.is_file()]
    if len(present) != 1:
        raise AdmissionError("both-mode worker readiness marker is ambiguous or unavailable")
    return {role: str(present[0]) for role in cohort}


def journal_context(workspace):
    value = read_json(Path(workspace) / "tmp/worker-admission.json")
    if type(value.get("protocol")) is not int or value["protocol"] != 1 or value.get("workspace") != workspace:
        raise AdmissionError("recorded recovery context is unsupported")
    target = value.get("target_revision")
    if not isinstance(target, str) or not re.fullmatch(r"[0-9a-f]{40}", target):
        raise AdmissionError("recorded target revision is unknown")
    roles = Drain.normalize_roles(value.get("roles"))
    gates = {Drain.normalize_path(path) for path in value.get("gates", roles.values())}
    parents = {path.parent for path in gates}
    if len(parents) != 1:
        raise AdmissionError("recorded readiness directory is ambiguous")
    directory = parents.pop()
    if any(ord(character) < 32 for character in str(directory)):
        raise AdmissionError("recorded readiness directory contains control characters")
    expected = {
        directory / "paid-worker-ready-temporal_worker",
        directory / "paid-worker-ready-temporal_worker-both",
        directory / "paid-worker-ready-temporal_worker-poll",
        directory / "paid-worker-ready-temporal_worker-agent"
    }
    if gates != expected or not set(roles.values()).issubset(gates):
        raise AdmissionError("recorded generation lacks complete launch-path coverage")
    return {"target_revision": target, "readiness_directory": str(directory),
            "roles": {role: str(path) for role, path in roles.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--controller-identity", type=int)
    parser.add_argument("--caller-pid", type=int)
    parser.add_argument("--reap-controller")
    parser.add_argument("--originals-gone", action="store_true")
    parser.add_argument("--journal", action="store_true")
    parser.add_argument("--absent", action="store_true")
    parser.add_argument("--marker-roles")
    parser.add_argument("--ready-target")
    parser.add_argument("--readiness-directory")
    arguments = parser.parse_args()
    try:
        workspace = str(Path(arguments.workspace).resolve(strict=True))
        if arguments.journal:
            print(json.dumps(journal_context(workspace), sort_keys=True))
            return 0
        if arguments.marker_roles:
            if not arguments.readiness_directory:
                raise AdmissionError("readiness directory is required")
            print(json.dumps(readiness_paths(json.loads(arguments.marker_roles), arguments.readiness_directory), sort_keys=True))
            return 0
        if arguments.absent:
            deadline = time.monotonic() + 5
            for _ in range(2):
                snapshot = process_snapshot(Path("/proc"), deadline)
                if any(value.get("workspace") == workspace and value.get("worker_roles") for value in snapshot.values()):
                    raise AdmissionError("workspace still has a Temporal worker")
            print(json.dumps({"absent": True}))
            return 0
        if arguments.controller_identity:
            if not arguments.caller_pid:
                raise AdmissionError("controller caller identity is required")
            print(json.dumps(controller_identity(arguments.controller_identity, arguments.caller_pid, workspace)))
            return 0
        if arguments.reap_controller:
            print(json.dumps(reap_controller(json.loads(arguments.reap_controller), workspace)))
            return 0
        status = sys.stdin.read(65537)
        if arguments.originals_gone:
            original_cohort_gone(json.loads(status))
            print(json.dumps({"gone": True}))
            return 0
        cohort = discover_cohort(arguments.workspace, status)
        if arguments.ready_target:
            if not arguments.readiness_directory:
                raise AdmissionError("target readiness directory is required")
            roles = readiness_paths(cohort, arguments.readiness_directory)
            reader = Drain(arguments.workspace, roles, arguments.ready_target, cohort)
            if any(reader.snapshot(role)["revision"] != arguments.ready_target for role in roles):
                raise AdmissionError("target boot revision is not verified")
        print(json.dumps(cohort, sort_keys=True))
        return 0
    except (AdmissionError, OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print(json.dumps({"status": "deferred", "reason": str(error) if isinstance(error, AdmissionError) else type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
