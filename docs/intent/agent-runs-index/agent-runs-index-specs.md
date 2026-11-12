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

- [x] **AGENT-RUNS-INDEX-004** — When an operator filters either Agent Runs
  index, the system SHALL accept only the allowlisted Ransack status,
  agent-type, goal, effective-runner, trigger-type, branch-name, and Temporal
  workflow-ID predicates; each categorical `*_in` predicate SHALL use OR
  semantics within that field, and categorical fields and text search SHALL
  compose with AND semantics.
  *Tests:* `spec/requests/agent_runs_spec.rb` ("filters account-wide runs with
  multi-select Ransack controls", "filters project runs with multi-select
  Ransack controls", "does not search unallowlisted run attributes"),
  `spec/system/agent_runs_filters_spec.rb`.
  *Code:* `app/models/agent_run.rb#ransackable_attributes`,
  `app/views/agent_runs/_filters.html.erb`.

- [x] **AGENT-RUNS-INDEX-005** — When an operator has active Agent Runs
  filters, either index SHALL expose the selected values, preserve the query in
  its GET URL and pagination links, and provide a reset action. Queue-priority
  sort SHALL apply only when all selected statuses are unfinished.
  *Tests:* `spec/requests/agent_runs_spec.rb` ("preserves active filters in
  pagination links", "keeps completed runs when queue sorting has mixed
  status selections"), `spec/system/agent_runs_filters_spec.rb`.
  *Code:* `app/controllers/agent_runs_controller.rb#queue_sort_compatible?`,
  `app/views/agent_runs/_filters.html.erb`.
