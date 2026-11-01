# EARS Specs: Cycle Repair and Sync Confirmation

> Testable claims for cycle repair application and automatic synchronization
> confirmation. Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r AUTO-PICK-QUEUE-021`).

## Cycle Repair Application

- [x] **AUTO-PICK-QUEUE-021** — When a cycle-analysis recommendation proposes
  declaration changes to break a cycle, Paid SHALL apply those changes by
  removing or correcting the specified IssueDependency edges. The repair SHALL
  be applied atomically — either all changes succeed or none are persisted.
  Each affected edge SHALL be marked with `repair_status=pending_sync` to track
  confirmation once the repair has been synchronized. The repair_outcome field
  SHALL record the action taken (remove/correct) and the timestamp. Repair_attempts
  SHALL be incremented on each application attempt.
  *Tests:* `spec/services/cycle_breakers/apply_spec.rb`.
  *Code:* `CycleBreakers::Apply`.

- [x] **AUTO-PICK-QUEUE-023** — When a cycle repair removes an IssueDependency
  edge, the edge SHALL be deleted from the database. When the repair corrects
  an edge (changes its endpoints), the original edge SHALL be updated or replaced
  with the corrected version. The repair_initiated_at timestamp SHALL be set
  on first application and persist across retry attempts.
  *Tests:* `spec/services/cycle_breakers/apply_spec.rb`.
  *Code:* `CycleBreakers::Apply`.

## Sync Confirmation

- [x] **AUTO-PICK-QUEUE-022** — After a cycle repair is applied, Paid SHALL
  automatically confirm the repair once the changes are synchronized to GitHub.
  Confirmation is detected when the dependency graph is checked and no cycle
  exists anymore. Edges with `repair_status=pending_sync` SHALL transition to
  `repair_status=confirmed` when the associated cycle is no longer present in
  the persisted, synchronized graph. Confirmation SHALL record a confirmed_at
  timestamp in the repair_outcome.
  *Tests:* `spec/services/cycle_breakers/confirm_sync_spec.rb`.
  *Code:* `CycleBreakers::ConfirmSync`, `CycleRepairSyncConfirmationJob`.

## Bounded Repair Retries

- [x] **AUTO-PICK-QUEUE-024** — Cycle repairs SHALL have a bounded retry limit
  to prevent infinite retry loops. After MAX_REPAIR_ATTEMPTS (3) application
  attempts, a repair that remains in a cycle SHALL be marked as `repair_status=failed`.
  The repair_outcome SHALL record the failure_reason and failed_at timestamp.
  Subsequent repair attempts for that edge SHALL be skipped.
  *Tests:* `spec/services/cycle_breakers/confirm_sync_spec.rb`.
  *Code:* `CycleBreakers::ConfirmSync`, `CycleBreakers::MAX_REPAIR_ATTEMPTS`.

- [x] **AUTO-PICK-QUEUE-025** — The CycleRepairSyncConfirmationJob SHALL run
  as a bounded maintenance task with concurrency control (one active pass per
  system), checking all pending_sync repairs across all accounts. The job SHALL
  transition repairs to confirmed or failed status based on the current graph
  state. Job executions SHALL log the count of confirmed, failed, and stale
  repairs for observability.
  *Tests:* `spec/jobs/cycle_repair_sync_confirmation_job_spec.rb`.
  *Code:* `CycleRepairSyncConfirmationJob`.
