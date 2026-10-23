# Agent Runs index specifications

- [x] **AGENT-RUNS-INDEX-001** — When the Agent Runs index renders, it SHALL
  omit filter controls whose corresponding scope has no values, retain
  controls for available values, and keep the filter section collapsed by
  default.
- [x] **AGENT-RUNS-INDEX-002** — When the Agent Runs index determines which
  status, agent-type, and goal filters are available, it SHALL cache those
  values separately for the authorized account and project scopes and
  invalidate the affected entries when an Agent Run changes those values.
