# EARS: Technical Prerequisite Validation

- [x] **TECHNICAL-PREREQUISITE-001** — When an authorized prerequisite validation runs, the system SHALL execute its selected analyzer only through the pinned AgentRun execution environment and SHALL durably record bounded stdout, stderr, exit status, analyzer/tool identity, checkout, endpoint identity, and a distinct succeeded, failed, unavailable, or setup-required outcome. When a requested sidecar rollout is disabled, it SHALL show the required scoped authorization action and SHALL neither enable the flag nor expose a host Docker socket.
