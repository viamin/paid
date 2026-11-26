"""Read-only supervisor-to-worker identity resolution.

@spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
"""

import argparse
import json
from pathlib import Path
import re
import sys
import time

from worker_admission import AdmissionError, Drain, supervisor_cohort


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--ready-target")
    parser.add_argument("--readiness-directory")
    arguments = parser.parse_args()
    try:
        status = sys.stdin.read(65537)
        cohort = discover_cohort(arguments.workspace, status)
        if arguments.ready_target:
            if not arguments.readiness_directory:
                raise AdmissionError("target readiness directory is required")
            directory = Path(arguments.readiness_directory)
            both = cohort["agent"] == cohort["poll"]
            roles = {role: directory / ("paid-worker-ready-temporal_worker-" + ("both" if both else role))
                     for role in cohort}
            reader = Drain(arguments.workspace, roles, arguments.ready_target, cohort)
            if any(reader.snapshot(role)["revision"] != arguments.ready_target for role in roles):
                raise AdmissionError("target boot revision is not verified")
        print(json.dumps(cohort, sort_keys=True))
        return 0
    except (AdmissionError, OSError, ValueError, KeyError, IndexError) as error:
        print(json.dumps({"status": "deferred", "reason": str(error) if isinstance(error, AdmissionError) else type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
