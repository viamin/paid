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
empty results so callers cannot treat policy suppression as a GitHub failure —
and the no-op is explicit: singular suppressed writes return the
`GithubClient::LabelWriteSuppressed` sentinel (detected via
`GithubClient.label_write_suppressed?`) and suppressed removal hashes carry
`suppressed: true`, so outcome-reporting callers — the `set_labels` MCP tool,
audit events, and priority-label sync — report and persist no label changes
instead of claiming suppressed mutations (LABEL-INTEGRATION-004).
`create_issue` is gated too: the issue itself is still created, but its
`labels:` argument — which adds labels in the same POST — is stripped when
writes are suppressed. `update_issue` similarly strips `labels:` so label
replacement cannot bypass the gate, including when a trusted-human fallback
credential is selected. Read paths deliberately remain intact except in
`ignored` mode. In that mode, Paid is the source of truth for control state:
`Issue#paused`, local PR merge holds, the TDD review gate, local priority, and
an auto-pick exclusion reason replace their corresponding label reads.
Escalation dismissal remains the existing local `PullRequests::Unblock`
transition, preserving its token-cap waiver and audit contract. The project
page and the MCP tool registry (and thus chat) expose reversible actions for
these local controls; manual run actions remain the activation surface.

The project settings form and `update_project_settings` MCP write surface
expose the setting; tenant configuration exposes the creation default.
