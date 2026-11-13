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
  Agent Runs index, it SHALL submit only allowlisted Ransack predicates through
  a shareable GET URL: `status_in`, `agent_type_in`, `goal_in`,
  `effective_runner_in`, and `trigger_type_in` categorical controls SHALL
  support multiple values with OR semantics within each field, and the text
  search control SHALL search only branch name and Temporal workflow ID. The
  account-wide index SHALL retain policy scope and synthetic-run exclusion; the
  project index SHALL retain its project scope. Active filters and a reset
  action SHALL be visible and the controls SHALL remain keyboard- and
  screen-reader-accessible.
- [x] **AGENT-RUNS-INDEX-005** — When queue-priority sorting is requested with
  Agent Runs filters, it SHALL apply only if every selected status is an
  unfinished status. A mixed or finished-status selection SHALL retain all
  Ransack matches under normal ordering instead of silently excluding rows.
