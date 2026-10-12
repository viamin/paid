# EARS Specs: Label Integration Mode

- [x] **LABEL-INTEGRATION-001** — When a project is created without an
  explicit label mode, it SHALL use its tenant's default; changing that default
  SHALL NOT change existing projects.

- [x] **LABEL-INTEGRATION-002** — When a project's mode is `read_only` or
  `ignored`, Paid SHALL NOT create, update, add, remove, or replace a GitHub
  label. Suppression SHALL be error-free and SHALL NOT cause a control-state
  transition to fail.

- [x] **LABEL-INTEGRATION-003** — The project settings UI and
  `update_project_settings` MCP tool SHALL expose the project's mode, and the
  tenant settings surface SHALL expose the default for new projects.

- [x] **LABEL-INTEGRATION-004** — When a label mutation is suppressed by
  project mode, outcome-reporting callers (the `set_labels` MCP tool and
  priority-label sync) SHALL report and audit no label changes, SHALL surface
  that the write was suppressed, and SHALL NOT alter locally persisted label
  state as if the mutation had been performed.

- [x] **LABEL-INTEGRATION-005** — When a project enters `ignored` from another
  mode, Paid SHALL idempotently import the currently label-derived paused and
  escalated states into their local representations before later label edits
  can be ignored. The import SHALL NOT interrupt an in-flight run.

- [x] **LABEL-INTEGRATION-006** — When a project is not `read_write`, an
  operator SHALL be able to preview and then explicitly execute removal of
  Paid-owned catalog labels from open issues and pull requests. The cleanup
  SHALL never delete label definitions or labels outside the catalog.

- [x] **LABEL-INTEGRATION-007** — Repeating an interrupted import or cleanup
  SHALL be safe. On return to `read_write`, standard-label provisioning SHALL
  restore the catalog; local state imported while ignored takes precedence over
  stale labels rather than being re-imported.
