# EARS Specs: Workspace Agent Chat

> Proposed claims for RDR-064. All are active gaps owned by #5351 after the
> owner accepts the exact RDR revision and the handoff becomes Final. Status
> markers: `[ ]` active gap.

- [ ] **WORKSPACE-AGENT-CHAT-001** — When an eligible user explicitly creates
  a workspace-agent chat while `container_agent_chat` is enabled for its
  approved account/project scope, the system SHALL persist its execution mode
  and display that native CLI tools can mutate the workspace under container
  permissions outside Paid structured-tool confirmation.
  *Planned tests:* permanent system mode-selection and chat-rendering spec;
  focused creation service spec.

- [ ] **WORKSPACE-AGENT-CHAT-002** — When a workspace-agent turn starts, the
  system SHALL select only a runner/model satisfying the persisted mode, ready
  workspace, scoped credential materialization, project policy, effective
  privacy requirement, and availability rules, then invoke its native CLI
  through `agent_harness` in that workspace; it SHALL NOT use Rails-host or
  disposable API-chat inference as a substitute.
  *Planned tests:* focused eligibility/invoker service specs and devcontainer
  native-CLI evidence per enabled runner.

- [ ] **WORKSPACE-AGENT-CHAT-003** — When building a workspace-agent turn, the
  system SHALL retain the complete system prompt and current user message,
  include at most 20 non-system messages including the current message, and
  omit older optional messages oldest first to fit a 64 KiB UTF-8 framed budget.
  If the complete required system prompt, current user message, and required
  framing together exceed that budget, it SHALL reject the turn before
  invocation without truncating required content or changing the readable
  transcript.
  *Planned tests:* focused context-rendering service specs for combined required
  content overflow even when each message individually fits, required framing,
  exact 64 KiB acceptance, UTF-8 byte boundaries, and optional-history omission.

- [ ] **WORKSPACE-AGENT-CHAT-004** — When a native CLI turn reports progress,
  completion, usage, cancellation, or failure, the system SHALL stream supported
  progress, apply the 60-second no-progress read deadline and 10-minute
  monotonic whole-turn deadline from RDR-064, persist final assistant content and
  sanitized mode/runner/model/container/request provenance, retain reported
  usage without inventing unknown values, and avoid persisting raw credentials
  or diagnostic output.
  *Planned tests:* focused invoker/accounting/cancellation specs.

- [ ] **WORKSPACE-AGENT-CHAT-005** — When a candidate fails or fallback is
  considered, the system SHALL preserve the persisted mode, effective privacy,
  credential/billing intent, and execution authority; if no compatible route
  exists, it SHALL fail before prompt transmission with an actionable error.
  *Planned tests:* focused fallback/privacy service specs.

- [ ] **WORKSPACE-AGENT-CHAT-006** — When a workspace is stale, stopped, or a
  turn is cancelled, the system SHALL use the existing lifecycle only before an
  invocation begins, preserve history, record one terminal outcome, and never
  replay a possibly started CLI invocation or duplicate an assistant reply.
  *Planned tests:* focused recovery/serialization specs and a permanent system
  history-preservation flow.

- [ ] **WORKSPACE-AGENT-CHAT-007** — When the flag is disabled or a session is
  incompatible with its mode, the system SHALL preserve history and reject the
  new turn unless the user explicitly creates or reconfigures an eligible
  session; it SHALL NOT silently switch mode, authentication, billing, privacy,
  runner authority, or tool confirmation semantics.
  *Planned tests:* permanent system flag/rollback flow and focused route guards.
