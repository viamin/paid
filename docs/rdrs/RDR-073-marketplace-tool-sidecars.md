# RDR-073: Marketplace Tool Sidecars — Per-Run Hardened Tool Provisioning

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-10-10
- **Status**: Draft
- **Type**: Architecture
- **Priority**: P1 `[inferred — not supplied by the feature brief]`
- **Related RDRs**: [RDR-020](RDR-020-service-container-architecture.md) (Service Container Architecture), [RDR-055](RDR-055-agent-container-egress-allowlisting.md) (Agent Container Egress Allowlisting), [RDR-058](RDR-058-execution-authority-network-and-isolation.md) (Execution Authority, Network Policy, and Isolation), [RDR-062](RDR-062-execution-network-policy-intent.md) (Provider-Neutral Execution Network Policy Intent)
- **Related Issues**: implementation issue tree filed by the creating run (one epic, four phase issues, one closeout issue); numbers are recorded in the epic issue body.

## Problem Statement

Paid can attach marketplace content to agent runs (prompts, MCP servers,
runtime config), and it can run always-on project service containers
(postgres, redis, browsers) managed by account admins. What it cannot do is
provision **specialized tooling as a per-run sidecar**: a project owner who
wants a particular tool (a linter server, a code-search daemon, a
domain-specific analysis service) available *inside* an agent run has no
first-class way to publish that tool and have Paid start it, hardened, only
when the run's context actually calls for it.

The gap is deliberately narrow. As the feature brief's supplied observations
state:

- Paid already has a fully functional marketplace + runtime attachments
  system — the gap is tool-specific sidecar provisioning, not building from
  scratch.
- The MCP provisioner already distinguishes `npx` (stdio inside the agent
  container) from `docker_image` (sidecar on the same Docker network); the
  brief's preferred shape ("Option A") adds a third `install_type` `"tool"`
  to that existing pattern.
- Hardening profiles already exist for service containers; reusing them for
  tool sidecars is the security-minimizing path.
- Rule conditions already exist on `MarketplaceEntryRule`; extending them to
  support `task_text_includes_any` and `issue_labels_includes_any` gives
  fine-grained scoping without new infrastructure.

Affected stakeholders (supplied by the brief):

- Project owners who want to use specialized tooling inside agent runs
- Platform operators managing container resources and hardening profiles
- Marketplace publishers who want to publish tools as first-class Paid entries
- End users whose agent runs may or may not invoke the tooling depending on
  run context

The brief supplies no selected problem framing (`selected_framing` is absent),
so the framing above — "extend the existing attachment + sidecar patterns
rather than build a new subsystem" — is carried by the brief's own
observations, not by a user-confirmed framing decision.

## Context

### Marketplace and runtime attachments today

- `MarketplaceEntry` (`app/models/marketplace_entry.rb:4-18`) already accepts
  `entry_type: "tool"` — the value exists in `ENTRY_TYPES` alongside
  `mcp_server`, `plugin`, `provider_config`, and others. Entries are
  account-scoped (`team_scope: "account"`), versioned through
  `MarketplaceEntryVersion` (`canonical_artifact` JSON is required,
  `app/models/marketplace_entry_version.rb:12`), and gated by `status`
  (draft/active/deprecated) plus certification metadata.
- `MarketplaceEntryRule` (`app/models/marketplace_entry_rule.rb:4-8`) carries
  `mode` (`automatic` / `team_default`), an `enabled` flag, `position`, and a
  free-form `conditions` JSON object evaluated by
  `MarketplaceEntries::Resolver#rule_matches?`
  (`app/services/marketplace_entries/resolver.rb:133-141`). Recognized
  condition keys today: `provider_keys`, `agent_types`, `goals`,
  `project_ids`, `repository_full_names`, and `task_text_includes_any`
  (substring match over `custom_prompt` + issue title/body,
  `resolver.rb:150-162`).
- `AgentRunMarketplaceEntry` (`app/models/agent_run_marketplace_entry.rb:4`)
  records how an entry attached: `automatic`, `team_default`, or `manual`.
- `MarketplaceEntries::Renderer` (`app/services/marketplace_entries/renderer.rb:57-62`)
  infers an `attachment_strategy` from entry type: `mcp_server` entries become
  MCP server snapshots, `plugin`/`provider_config` become `runtime_config`,
  everything else — including `tool` — falls through to `prompt_append`.
- `MarketplaceEntries::RuntimeAttachments.mcp_server_snapshots`
  (`app/services/marketplace_entries/runtime_attachments.rb:45-59`) filters
  attachments whose rendered payload has
  `attachment_strategy == "mcp_server"` and merges them into the run's
  `mcp_server_snapshot` via `McpSnapshotSync`
  (`app/services/marketplace_entries/mcp_snapshot_sync.rb`).

### Sidecar provisioning today (the pattern being extended)

- `Containers::McpProvisioner#provision`
  (`app/services/containers/mcp_provisioner.rb:59-109`) reads
  `agent_run.mcp_server_snapshot` and switches on `install_type`:
  `"npx"` materializes a stdio server spec for the agent execution layer;
  `"docker_image"` provisions a sidecar container on the agent's Docker
  network (`NetworkPolicy::NETWORK_NAME = "paid_agent"`,
  `app/services/network_policy.rb:42`).
- Docker sidecars get a stable per-run hostname/alias
  (`paid-mcp-<name>-run<id>`, `mcp_provisioner.rb:254-259`), resource limits
  (1 GiB memory, CPU quota, pids limit, `mcp_provisioner.rb:37-41`), a TCP
  health probe with timeout (`mcp_provisioner.rb:240-252`), tracking labels
  (`paid.mcp_sidecar`, `paid.agent_run_id`), idempotent adoption across
  activity retries, and cleanup of stale sidecars from prior attempts.
- Provisioning is invoked from the run lifecycle
  (`app/temporal/activities/provision_mcp_servers_activity.rb`,
  `app/services/execution_runners/local_docker_runner.rb:322-327`,
  `app/temporal/activities/run_agent_activity.rb:892`) and cleaned up with
  the run. Container IDs are persisted on `agent_runs.mcp_sidecar_container_ids`
  (`db/migrate/20260504100425_add_mcp_sidecar_container_ids_to_agent_runs.rb`).
- `McpServerDefinition::INSTALL_TYPES = %w[npx docker_image]`
  (`app/models/mcp_server_definition.rb:6`) — the project-level MCP
  definition path validates against exactly these two values.

### Service-container hardening (the security baseline to reuse)

- `Containers::ServiceProvisioner` applies baseline hardening to every
  service container: all capabilities dropped, `no-new-privileges`
  (`app/services/containers/service_provisioner.rb:92-105`, issue #3450,
  `@spec CONTAINER-RUNTIME-040`).
- Known image families get profiled hardening — read-only root filesystem,
  non-root runtime user, sized tmpfs mounts, minimal `cap_add` — via
  `HARDENING_PROFILES` + `HARDENING_PROFILE_MATCHERS`
  (`service_provisioner.rb:106-165`), merged with operator overrides stored
  under the `PAID_SERVICE_HARDENING` env key
  (`service_provisioner.rb:89`, `:691-727`), with `readonly_rootfs`/`user`
  overrides refused for built-in families and `cap_add` restricted to
  `SAFE_OVERRIDE_CAPABILITIES`.
- Service container images are validated against an account allowlist
  (`ServiceContainer#image_in_allowlist`, `app/models/service_container.rb:74-83`;
  allowlist stored in `UserSettings.allowed_service_images`,
  `db/migrate/20260228120000_create_service_containers.rb:28-29`).

### Run-context signals available for rule scoping

- Issue labels are cached on `issues.labels` (JSONB,
  `db/migrate/20260129043009_create_issues.rb:18`; `Issue#has_label?`,
  `app/models/issue.rb:262`).
- `Project#effective_repo_profile`
  (`app/models/project.rb:953-964`) exposes `languages` and `marker_files`
  detected by `Projects::DetectRepoProfile`
  (`app/services/projects/detect_repo_profile.rb:41-51`).
- MCP sidecars today do **not** receive the service-container hardening
  baseline: `create_sidecar_container` (`mcp_provisioner.rb:202-230`) sets
  resource limits and network mode but no capability drop, no
  `no-new-privileges`, no read-only rootfs/tmpfs profile.

### Rollout infrastructure

- `FeatureFlags::DEFINITIONS` (`app/services/feature_flags.rb:10`) defines
  named flags with owner, intent, rollout plan, and cleanup criteria; runtime
  decisions read `FeatureFlags.enabled?(:flag_name, project:)`. The standard
  enablement surface is per-tenant opt-in via `tenant_settings.features`.

## Research Findings

Investigation performed 2026-10-10 against `main` (post RDR-072). Findings
with file evidence:

1. **`entry_type: "tool"` is already legal but does nothing runtime.** The
   value exists in `MarketplaceEntry::ENTRY_TYPES`
   (`app/models/marketplace_entry.rb:4-18`), but `Renderer#inferred_attachment_strategy`
   (`app/services/marketplace_entries/renderer.rb:57-62`) maps it to
   `prompt_append` — a tool entry today can only inject prompt text, never
   provision anything.
2. **The provisioning switch is a two-arm `case` waiting for a third arm.**
   `McpProvisioner#provision` (`mcp_provisioner.rb:81-90`) dispatches on
   `install_type` with `"npx"` and `"docker_image"` arms; everything else is
   silently ignored. The snapshot pipeline that feeds it
   (attachment render → `RuntimeAttachments.mcp_server_snapshots` →
   `McpSnapshotSync`) is entry-type-agnostic once the rendered payload
   carries the right `attachment_strategy`.
3. **`task_text_includes_any` already exists; label/file/language conditions
   do not.** `Resolver#rule_matches?` (`resolver.rb:133-141`) already
   evaluates `task_text_includes_any` — the brief's observation that prompt
   text scoping exists is confirmed at `resolver.rb:150-162`. There is no
   `issue_labels_includes_any`, no repository-file condition, and no language
   condition anywhere in the resolver.
4. **Hardening is mature but sidecars bypass it.** `ServiceProvisioner`
   hardening (`service_provisioner.rb:89-165`) is exactly the
   security-minimizing mechanism the brief asks to reuse, but MCP sidecars
   created by `McpProvisioner` get resource limits only — no capability drop,
   no `no-new-privileges`, no profiled rootfs/tmpfs — because they are built
   by a separate container-creation path
   (`mcp_provisioner.rb:202-230` vs `service_provisioner.rb:603-649`).
5. **A stable DNS alias per sidecar is established practice.** Docker
   network aliases (`mcp_provisioner.rb:217-222`) make the sidecar reachable
   by hostname on `paid_agent`; the MCP path already relies on this
   (`http://<hostname>:<port>/sse`, `mcp_provisioner.rb:170`).
6. **Run-lifecycle integration points exist end-to-end.** Snapshot columns
   (`mcp_server_snapshot`, `mcp_provisioned_servers`,
   `mcp_sidecar_container_ids` on `agent_runs`), provisioning activities,
   and cleanup paths (`local_docker_runner.rb:322-327`) all already handle
   "containers that belong to this run and must die with it".
7. **The image allowlist is an operator surface, not a marketplace surface.**
   `UserSettings.allowed_service_images` gates `ServiceContainer` records;
   nothing today gates which *images a marketplace entry* may ask Paid to
   run. A tool sidecar feature that accepts arbitrary images from entry
   payloads would create a new, unreviewed code-execution channel — the
   allowlist (or an equivalent operator gate) must apply at provisioning
   time, not only at `ServiceContainer` creation.

No evidence was found of any prior attempt at tool sidecar provisioning
(searched `app/services`, `app/models`, `db/migrate`, and `docs/rdrs/` for
tool/sidecar combinations; the only sidecar machinery is the MCP provisioner
above).

## Proposed Solution

Extend the existing marketplace → attachment → provisioner pipeline with a
third install type, reusing the MCP sidecar pattern and the service-container
hardening baseline. Four components:

### 1. Tool attachment contract (marketplace side)

- A marketplace entry with `entry_type: "tool"` publishes a
  `canonical_artifact` describing a Docker tool sidecar: `install_type:
  "tool"`, `image`, `port`, optional `env`, and an optional `alias` `[inferred
  — artifact field names follow the docker_image precedent in
  McpProvisioner]`.
- `Renderer#inferred_attachment_strategy` maps `entry_type: "tool"` to a
  `tool_sidecar` attachment strategy (mirroring how `mcp_server` infers its
  strategy, `renderer.rb:57-62`); the existing strategy-tag mechanism in the
  rendered payload needs no schema change.
- A `tool_sidecar` attachment contributes a provisioning definition to the
  run snapshot alongside — not inside — MCP server definitions, so MCP
  semantics (stdio/url servers, SSE transport validation) are not overloaded
  onto tools.

### 2. Fine-grained scoping (rule conditions)

Extend `MarketplaceEntries::Resolver#rule_matches?` with three condition
keys, all optional and conjunctive with existing keys, all evaluated from
data already loaded at run-creation time:

- `issue_labels_includes_any` — any-of match against
  `agent_run.issue.labels` (JSONB array).
- `languages_include_any` — any-of match against
  `project.effective_repo_profile["languages"]`.
- `repo_files_include_any` — any-of match against
  `project.effective_repo_profile["marker_files"]` (detected marker files;
  a full repository-tree condition would require clone-time evaluation and
  is explicitly out of scope `[inferred]`).

`task_text_includes_any` already exists and needs no change (confirmed,
`resolver.rb:150-162`).

### 3. Hardened sidecar provisioning (the third install arm)

- `McpProvisioner#provision`'s `install_type` case gains a `"tool"` arm
  (renamed/split in the LLD if cleaner) that provisions a sidecar using the
  existing docker_image machinery — same network (`paid_agent`), same
  per-run hostname/alias pattern, same health probe, same retry/idempotency
  and cleanup behavior — with two differences:
  - **Hardening**: the container is created through the
    `ServiceProvisioner` hardening profile path (all capabilities dropped,
    `no-new-privileges`, image-family `HARDENING_PROFILES` where they match,
    `DEFAULT_HARDENING_PROFILE` otherwise) instead of the limits-only MCP
    creation. Tool entries may carry a `PAID_SERVICE_HARDENING`-shaped
    override subject to the same validation rules as service-container
    overrides (`service_provisioner.rb:691-727`).
  - **No MCP semantics**: a tool sidecar is not registered as an MCP url
    server; it is a plain TCP/HTTP endpoint.
- **Image gating**: provisioning refuses any image not permitted for the
  account. The default evaluation is against the operator allowlist surface
  (`UserSettings.allowed_service_images` or an operator-managed equivalent
  to be settled in the LLD `[inferred]`) so a marketplace entry cannot
  introduce an unreviewed image into the execution environment.
- The agent reaches the tool at a stable DNS alias derived from the entry
  name (sanitized, per-run-scoped like `paid-mcp-<name>-run<id>`), exposed
  to the agent as an environment variable / prompt-visible endpoint note
  `[inferred — exact exposure mechanism is LLD work]`.

### 4. Run lifecycle integration

- Provisioned tool sidecar container IDs are persisted on the agent run
  (a `tool_sidecar_container_ids` column `[inferred]`, mirroring
  `mcp_sidecar_container_ids`), so retries, cleanup jobs, stale-run
  detection, and orphan cleanup treat them exactly like MCP sidecars.
- Provisioning and cleanup are wired at the same lifecycle points as MCP
  provisioning (`ProvisionMcpServersActivity`,
  `ExecutionRunners::LocalDockerRunner`, run cleanup).
- Structured logging uses the `container_manager` / `agent_execution`
  component names with `agent_run_id`, tool name, image, and container ID.
- Sidecars are strictly optional per run: a run with no matching tool
  attachments provisions nothing, and a disabled flag (below) is
  behaviorally identical to "no tools attached".

### Decision rationale

1. **Third install arm, not a new subsystem.** The brief's supplied
   observation is correct: the snapshot → provisioner → sidecar → cleanup
   pipeline already solves networking, aliasing, health checking,
   idempotency, and cleanup. A new tool-provisioning subsystem would
   duplicate all of it.
2. **Reuse service-container hardening rather than inventing a tool-specific
   profile system.** `HARDENING_PROFILES` + override validation already
   encode the operator-controlled security model; a second, weaker path
   would be a regression (finding 4).
3. **Rule conditions over new infrastructure.** `MarketplaceEntryRule`
   conditions are data; adding three evaluation keys to one predicate keeps
   scoping declarative and reviewable instead of adding new join tables or
   services (brief observation 4).
4. **Fail closed on ungated images.** Marketplace payloads are
   tenant-authored content; letting them name arbitrary Docker images would
   make the marketplace a code-execution channel bypassing the operator
   allowlist that already governs service containers (finding 7).

## Alternatives Considered

### Alternative A: Build a dedicated tool-provisioning subsystem

**Description**: New `ToolProvisioner` service, new tool registry table, new
lifecycle activities — parallel to but independent of the MCP provisioner.

**Pros**: Clean domain separation; no risk of destabilizing MCP provisioning.

**Cons**: Duplicates networking, aliasing, health checks, idempotent
adoption, cleanup, and run-lifecycle wiring that `McpProvisioner` and the
sidecar columns already provide; doubles the security surface to audit.

**Reason for rejection**: The brief's supplied framing ("Option A just adds a
third install_type") is also the engineering judgment the evidence supports —
the existing pattern carries every required behavior except hardening and
image gating.

### Alternative B: Always-on project service containers instead of per-run sidecars

**Description**: Model tools as `ServiceContainer` records attached to
projects (the RDR-020 mechanism), started whenever any run needs them.

**Pros**: Zero new provisioning code; operators already manage these.

**Cons**: Contradicts the brief's desired outcome ("Sidecars are optional per
run, not always-on"); always-on containers consume resources between runs,
outlive the run's network (service containers are not on `paid_agent` by
design), and couple unrelated runs to shared state.

**Reason for rejection**: Fails the per-run isolation and optional-provisioning
requirements; wrong lifecycle.

### Alternative C: stdio tools only (no sidecars)

**Description**: Support tools exclusively as in-container commands (the
`npx` pattern) — no Docker sidecars at all.

**Pros**: Simplest possible runtime; no new container hardening surface.

**Cons**: The brief's desired outcome explicitly centers on
`docker_image`-style tooling with a stable DNS alias; long-running daemons,
HTTP tooling, and polyglot runtimes cannot be expressed as stdio commands
inside the agent container.

**Reason for rejection**: Does not satisfy the stated user outcome.

### Alternative D: Status quo — publish tools as `mcp_server` entries

**Description**: Encourage publishers to use `entry_type: "mcp_server"` with
`install_type: "docker_image"` today; no code changes.

**Pros**: Ships today with zero work.

**Cons**: Forces MCP semantics onto non-MCP tools (SSE transport is
mandatory for docker_image sidecars, `mcp_provisioner.rb:140-143`);
`mcp_server` entries register as MCP url servers in the agent's server list,
misrepresenting a plain tool; sidecars keep the limits-only (unhardened)
creation path; no label/file/language scoping.

**Reason for rejection**: Semantic mismatch plus leaves the hardening gap
(finding 4) in the path the feature would encourage people to use.

## Trade-offs and Consequences

### Positive consequences

- Project owners gain a declarative, rule-scoped way to run specialized
  tooling per run, with a stable DNS alias inside the isolated run network.
- The MCP sidecar pattern gains hardening for its own future use if the LLD
  unifies container creation behind the `ServiceProvisioner` path.
- No new scheduling, networking, or cleanup concepts — operators reason about
  tool sidecars with the same mental model as MCP sidecars.
- Marketplace publishers get a first-class `tool` entry type whose runtime
  behavior matches its name.

### Negative consequences

- Two sidecar flavors (MCP vs tool) share a provisioner until/unless the LLD
  unifies them; the shared `case` must stay honest about which semantics
  apply to which arm.
- Extending rule conditions invites condition-key sprawl; the condition
  vocabulary should stay small and documented.
- Per-run sidecars add container startup latency (image pull + health check)
  to runs that match tool rules.
- The image-gate decision may force operators to extend allowlists before
  tenants can use published tools — deliberate friction, but friction.

### Risks and mitigations

- **Risk**: A tool image runs as root / escapes the limits-only shape.
  **Mitigation**: mandatory capability drop + `no-new-privileges` +
  resource limits at creation (Alternative paths that skip hardening fail
  closed); image-family profiles where known.
- **Risk**: Marketplace entry carries an unreviewed or hostile image.
  **Mitigation**: account-level image gate at provisioning time (finding 7);
  certification metadata on the entry remains the publishing-side signal.
- **Risk**: Sidecar leaks (failed runs, retries).
  **Mitigation**: same tracking-label + persisted-ID + orphan-cleanup
  machinery as MCP sidecars; cleanup verifies labels before removal.
- **Risk**: Rule evaluation cost on run creation.
  **Mitigation**: all new condition keys evaluate from already-loaded data
  (issue labels, repo profile) — no new queries per rule.

## Rollout Guard

This RDR changes runtime behavior (new container provisioning path), so it
ships behind a feature flag:

- **Flag**: `marketplace_tool_sidecars`, added to `FeatureFlags::DEFINITIONS`
  (`app/services/feature_flags.rb`) by the Phase 1 implementation issue,
  with owner `marketplace-runtime`, intent, rollout plan, and cleanup
  criteria per the existing `Definition` shape.
- **Default state**: off. Runtime provisioning decisions read
  `FeatureFlags.enabled?(:marketplace_tool_sidecars, project:)`; when
  disabled, `tool_sidecar` attachments resolve and record like today
  (prompt-only) but never provision containers — behaviorally identical to
  pre-feature.
- **Enablement surface**: per-tenant opt-in via `tenant_settings.features`,
  consistent with `execution_runner_enabled` and peers.
- **Rollback action**: disable the flag for the tenant (no data migration
  needed; provisioned sidecars clean up with their runs; the flag only gates
  provisioning).
- **Cleanup criteria**: remove the flag once the RDR-073 closeout audit
  verifies the hardened provisioning path is complete, image gating is
  enforced, and pilot tenants have run tool-attached runs without incident.

## Implementation Plan

Prerequisite: this RDR accepted (human review on the docs-only PR). A
`lid_planning` run converts this RDR into LID artifacts (`docs/intent/
marketplace-tool-sidecars/`); implementation issues carry `@spec
TOOL-SIDECAR-###` annotations against those EARS specs.

### Phase 1: Tool attachment contract + rollout guard

- Add `marketplace_tool_sidecars` to `FeatureFlags::DEFINITIONS` and wire the
  runtime gate.
- Define the `tool_sidecar` attachment strategy: `Renderer` inference for
  `entry_type: "tool"`, artifact schema validation (`install_type`, `image`,
  `port`), and snapshot contribution via the attachments pipeline.
- `@spec TOOL-SIDECAR-001`, `TOOL-SIDECAR-002`

### Phase 2: Rule condition extensions

- Add `issue_labels_includes_any`, `languages_include_any`, and
  `repo_files_include_any` evaluation to
  `MarketplaceEntries::Resolver#rule_matches?`, conjunctive with existing
  keys, sourced from `issue.labels` and `effective_repo_profile`.
- `@spec TOOL-SIDECAR-003`, `TOOL-SIDECAR-004`

### Phase 3: Hardened sidecar provisioning

- Add the `"tool"` install arm: sidecar creation through the
  `ServiceProvisioner` hardening profile path (caps dropped,
  `no-new-privileges`, family profiles, override validation), per-run DNS
  alias, health probe, resource limits.
- Enforce the account image gate at provisioning time.
- `@spec TOOL-SIDECAR-005`, `TOOL-SIDECAR-006`

### Phase 4: Run lifecycle integration and exposure

- Persist tool sidecar records on the agent run; wire provisioning and
  cleanup into the existing MCP lifecycle points; expose the alias/endpoint
  to the agent; structured logging and metrics.
- `@spec TOOL-SIDECAR-007`

### Closeout

- RDR closeout/validation issue following
  [`closeout-checklist.md`](closeout-checklist.md); depends on Phases 1–4;
  updates RDR status and the README index.

## Validation

### Implementation acceptance criteria (verifiable in code and tests)

1. A `tool` entry with a conforming canonical artifact attaches
   (automatic/team_default/manual) and contributes a `tool_sidecar`
   provisioning definition to the run snapshot. (`TOOL-SIDECAR-001`)
2. With the flag off, no tool sidecar containers are created; run behavior
   matches pre-feature. (`TOOL-SIDECAR-002`)
3. Rule matching honors `issue_labels_includes_any`,
   `languages_include_any`, and `repo_files_include_any`, each
   independently optional, conjunctive with existing conditions; empty
   arrays behave as "no constraint". (`TOOL-SIDECAR-003/004`)
4. A matching attached tool provisions exactly one sidecar on `paid_agent`
   with: capabilities dropped, `no-new-privileges`, resource limits,
   image-family hardening profile where applicable, and a stable per-run DNS
   alias reachable from the agent container. (`TOOL-SIDECAR-005`)
5. Provisioning fails closed for images not permitted for the account, and
   for hardening overrides that violate the service-container override
   rules. (`TOOL-SIDECAR-006`)
6. Sidecar container IDs are persisted on the run; retries adopt existing
   sidecars idempotently; run cleanup and orphan cleanup remove them;
   failed provisioning cleans up partially created containers.
   (`TOOL-SIDECAR-007`)
7. Docs-only RDR PR contains only `docs/rdrs/` changes (this document).

### Testing approach

- Unit: artifact schema validation; `Renderer` strategy inference; resolver
  condition predicates (labels/languages/marker files, including empty and
  absent keys); flag gating.
- Unit/integration (Docker-required, follow the `McpProvisioner` spec
  pattern): container creation asserts the hardening HostConfig (caps,
  `no-new-privileges`, memory/pids), network + alias, labels; image-gate
  refusal; health-probe timeout path; idempotent adoption; cleanup.
- Integration: end-to-end attach → provision → alias resolution → run
  cleanup; flag-off produces no containers.

### Test scenarios

1. **Scenario**: active `tool` entry with an `automatic` rule scoped by
   `issue_labels_includes_any: ["tooling"]`; a run whose issue carries the
   label.
   **Expected**: sidecar provisioned once, hardened, reachable by alias;
   run without the label provisions nothing.
2. **Scenario**: same entry, flag disabled tenant-wide.
   **Expected**: attachment recorded, no container created, no error.
3. **Scenario**: entry whose image is outside the account allowlist.
   **Expected**: provisioning fails closed with a logged, actionable error;
   run proceeds without the tool.
4. **Scenario**: provisioning activity retried after a partial failure.
   **Expected**: existing sidecar adopted, no duplicates, stale containers
   cleaned.
5. **Scenario**: run completes or fails.
   **Expected**: sidecar removed with the run; no orphaned containers.

### Desired user outcome (not yet achieved — supplied by the brief)

A project owner can publish a tool as a marketplace entry
(`entry_type: "tool"`) with a docker_image canonical artifact, attach it to
agent runs via automatic or manual rules (scopable by prompt text, issue
labels, repo files, languages), and Paid will provision a hardened sidecar
container on the agent's Docker network only when the run context matches.
The agent can reach the tool at a stable DNS alias. Sidecars are optional
per run, not always-on.

Achieving this outcome is the closeout criterion; the acceptance criteria
above are necessary but not sufficient evidence that the outcome (adoption,
usefulness to project owners) has been realized. The brief supplies no
reconsideration conditions and no evidence of user demand beyond the
stakeholder list; both are flagged for the human reviewer on the RDR PR.

## Notes

- The `McpServerDefinition` project-level path (`INSTALL_TYPES`) is
  deliberately untouched: this RDR is about marketplace tool entries, not
  project MCP definitions. If the LLD unifies the provisioner arms, that
  model's validation stays MCP-specific.
- EARS spec IDs referenced by the implementation issue tree
  (`TOOL-SIDECAR-001..007`) are prospective: the `lid_planning` run that
  follows this RDR materializes them in
  `docs/intent/marketplace-tool-sidecars/`; issue `@spec` annotations target
  those IDs so implementation runs are LID-aware from the start.
