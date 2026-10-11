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
