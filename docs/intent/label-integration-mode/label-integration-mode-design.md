# LLD: Label Integration Mode

> parent: docs/high-level-design.md
> prefix: LABEL-INTEGRATION

## Design

Each project has `label_integration_mode`: `read_write`, `read_only`, or
`ignored`. New projects inherit `TenantSetting#default_label_integration_mode`
at creation, without changing existing projects when the tenant setting later
changes. `read_write` is the default and preserves existing behavior.

`Labels::WritePolicy` is the sole authority for GitHub label mutations. Project
GitHub clients are decorated with its gate, and label provisioning checks it
before even listing remote labels. Suppressed operations return successful,
empty results so callers cannot treat policy suppression as a GitHub failure.
Read paths deliberately remain intact; the broader internal-control behavior
for ignored mode is deferred.

The project settings form and `update_project_settings` MCP write surface
expose the setting; tenant configuration exposes the creation default.
