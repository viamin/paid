# Soft Delete For Filter-Backed Records

`Provider` now uses `discard` because provider names surface in agent-run history and filter labels, and hard deletion caused routed filter values like `provider:123` to lose their display name.

Use `discard` for low-volume reference/configuration tables only when both of these are true:

- The record's human-readable name appears in a UI filter or historical detail view.
- Recreating the record later should not erase the historical label attached to old rows.

Near-term candidates if they gain the same historical filter problem:

- `ConfigurationBundle`
- `Prompt`
- `ServiceContainer`
- `StyleGuide`

Do not apply soft delete to high-volume operational tables. The storage and query cost is not justified there.

- `AgentRun`
- `AgentRunLog`
- `AgentRunPhase`
- `ChatMessage`
- `CollectorRun`
- `TokenUsage`
