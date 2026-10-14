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

- [x] **LABEL-CONTROL-001** — When a project's mode is `ignored`, Paid SHALL
  use persisted local control state rather than GitHub labels for pause,
  auto-pick exclusion, priority, per-PR merge holds, and the TDD test-review
  gate; `read_write` and `read_only` SHALL retain label-derived behavior.

- [x] **LABEL-CONTROL-002** — When a project is in `ignored` mode, authorized
  operators SHALL be able to set and clear each local control state from the
  project page and the MCP/chat control action.

- [x] **LABEL-CONTROL-003** — When an ignored-mode issue has an auto-pick
  exclusion reason, Paid SHALL not select it automatically; ordering SHALL use
  its local P1/P2/P3 priority. Upstream auto-pick control labels, including
  `epic`, SHALL NOT affect selection or re-audit eligibility in this mode.

- [x] **LABEL-CONTROL-004** — When an ignored-mode pull request has a local
  skip-auto-merge or hold-for-review flag, Paid SHALL block automatic merge
  without consulting the corresponding label, and SHALL surface a local review
  hold in the Inbox even before an auto-merge blocker snapshot exists.

- [x] **LABEL-CONTROL-005** — When an ignored-mode TDD pull request is at a
  local ready-for-review, approved, or changes-requested gate state, Paid SHALL
  use that state to preserve the human test-review gate independently of
  whether upstream label writes are enabled. Paid SHALL retain the local
  approval transition time and use it to avoid scheduling more than one
  implementation run for the same approved test revision. When a PR record is
  reconciled after its initial sync was unavailable, Paid SHALL restore a
  missing ready-for-review state from its test-writing run without replacing an
  existing operator decision.

- [x] **LABEL-CONTROL-006** — When an ignored-mode project has
  `auto_scan_prs` enabled, Paid SHALL scan each eligible open local pull request
  regardless of its automation or feature-activation labels. When the setting
  is disabled, Paid SHALL not use those labels as a PR-scanning activation
  channel.

- [x] **LABEL-CONTROL-007** — When an ignored-mode project has
  `auto_scan_prs` enabled, Paid SHALL scan an open PR linked to Paid work, an
  explicitly paid-activated PR, or a PR whose parent issue is paid-activated.
  An explicit PR deactivation SHALL override each of those scan-eligibility
  paths. An explicit PR or parent activation SHALL authorize scanning of an
  externally opened PR without consulting a GitHub label.

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
