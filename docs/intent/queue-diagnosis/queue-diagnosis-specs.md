# Queue diagnosis EARS

- [x] **QUEUE-DIAGNOSIS-001** — When a visible empty queue has eligible
  candidates and no queued runs, the dashboard SHALL report runnable work not
  seeded and name the bounded eligibility sweep as the recovery path.
- [x] **QUEUE-DIAGNOSIS-002** — When a visible empty queue has active runs and
  no waiting eligible or queued work, the dashboard SHALL report healthy active
  work rather than a stall.
- [x] **QUEUE-DIAGNOSIS-003** — When a visible empty queue has no eligible
  candidates and excluded open work, the dashboard SHALL report genuine holds
  and route human decision or dependency investigation to Inbox.
- [x] **QUEUE-DIAGNOSIS-004** — When normal admission is deliberately paused,
  the dashboard SHALL report a resource or policy pause and SHALL not suggest
  bypassing it.
- [x] **QUEUE-DIAGNOSIS-005** — When canonical eligibility or queue data is
  unavailable, the dashboard SHALL report unknown coverage and a refresh
  recovery action, never proof that no work exists.
