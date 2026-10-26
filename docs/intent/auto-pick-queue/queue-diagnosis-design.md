---
parent: AUTO-PICK-QUEUE
prefix: AUTO-PICK-QUEUE
---

# Low-Level Design: Queue Diagnosis

The Upcoming Queue is a projection of scheduler-visible queued runs, not a
count of open issues. The eligibility breakdown owns the companion diagnosis
because it already uses the canonical Auto-Pick candidate scope.

For every visible, active Auto-Pick project the projection reports separate
eligible-candidate, backend-queued, and active-run counts. It classifies an
empty waiting queue as healthy active work when no candidate waits and a run is
active; runnable-but-unseeded when canonical candidates exist but no queued run
does; an intentional policy pause when a project/account/quality gate stops
admission; and held when open work is excluded by canonical guards. Rendering
only reads persisted scheduler and eligibility data: it never invokes an LLM,
executes repository code, or mutates remote state.

The existing event-driven enqueue paths and bounded `AutoPickEligibilitySweepJob`
remain the recovery path for runnable-but-unseeded work. They reuse
`BulkEnqueueEligible` and its existing duplicate, authorization, budget,
dependency, planning-hold, and rollout controls; diagnosis never clears labels
or overrides an operator pause.
