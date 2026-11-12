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
- [x] **AGENT-RUNS-INDEX-004** — When an authorized operator filters either
  Agent Runs index, it SHALL use only allowlisted Ransack predicates: `_in`
  predicates for available status, agent-type, goal, effective-runner, and
  trigger-type values, and `branch_name_or_temporal_workflow_id_cont` for text
  search. Multiple selected values for one categorical field SHALL have OR
  semantics.
- [x] **AGENT-RUNS-INDEX-005** — When Agent Runs filters or sorting are active,
  the index SHALL retain its `q` GET query through pagination and table sort
  links, identify active filters to assistive technology, and offer a reset
  action. Queue-priority ordering SHALL apply only for exactly one unfinished
  selected status; all other filter combinations SHALL use normal ordering.
