---
parent: queue-diagnosis
prefix: QUEUE-DIAGNOSIS
---

# Queue Diagnosis EARS

- [x] **QUEUE-DIAGNOSIS-001** — When visible auto-pick projects have eligible candidates and no queued or active runs, the dashboard SHALL report runnable-but-unseeded work, show the distinct counts, and list bounded eligible issue provenance with the auto-pick sweep as the recovery path.
- [x] **QUEUE-DIAGNOSIS-002** — When the waiting queue is empty because visible eligible work is active, the dashboard SHALL report healthy active work rather than a failure.
- [x] **QUEUE-DIAGNOSIS-003** — When visible open work is excluded by dependencies or feature holds, the dashboard SHALL report a genuine hold and expose the issue-level blocker provenance and last local assessment time.
- [x] **QUEUE-DIAGNOSIS-004** — If canonical eligibility or scheduler data is unavailable, the dashboard SHALL report unknown coverage and a refresh action, and SHALL NOT infer that no work exists.
- [x] **QUEUE-DIAGNOSIS-005** — The diagnosis SHALL use the same account and owner visibility as eligibility breakdown and SHALL NOT expose another tenant's projects or issues.
