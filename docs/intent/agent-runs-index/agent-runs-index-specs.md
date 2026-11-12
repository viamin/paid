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
- [x] **AGENT-RUNS-INDEX-004** — When an operator filters an Agent Runs index,
  it SHALL submit allowlisted Ransack predicates for multi-value status, goal,
  agent type, runner, and trigger selections, and SHALL compose those filters
  with an allowlisted branch-name or workflow-identifier text search.
- [x] **AGENT-RUNS-INDEX-005** — When an Agent Runs filter is active, the index
  SHALL retain it in pagination and sort URLs, identify active filtering to
  assistive technology, and provide a reset link. Queue ordering SHALL apply
  only when every selected status is unfinished.
