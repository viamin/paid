# Agent Runs index specifications

- [x] **AGENT-RUNS-INDEX-001** — When the Agent Runs index renders, it SHALL
  omit filter controls whose corresponding scope has no values, retain
  controls for available values, and keep the filter section collapsed by
  default.
- [x] **AGENT-RUNS-INDEX-002** — When the Agent Runs index determines which
  status, agent-type, and goal filters are available, it SHALL cache those
  values separately for the authorized account and project scopes and
  invalidate the affected entries when an Agent Run changes those values.
- [x] **AGENT-RUNS-INDEX-003** — When the account-wide Agent Runs index loads a
  page of runs, it SHALL omit large run payload columns that are unused by the
  index while retaining the context text displayed in the table.
- [x] **AGENT-RUNS-INDEX-004** — When an operator filters an authorized,
  non-synthetic Agent Runs index, it SHALL submit the allowlisted Ransack
  `*_in` predicates for status, agent type, goal, effective runner, and
  trigger type, and SHALL compose those categorical filters with the
  allowlisted `run_text_cont` search predicate in the shareable GET URL.
- [x] **AGENT-RUNS-INDEX-005** — When the account-wide Agent Runs index
  requests queue-priority sorting, it SHALL use queue ordering only when every
  selected status is unfinished; otherwise it SHALL retain newest-first
  ordering and communicate that constraint in the filter UI.
