# Execution Runners — Closeout Audit (2026-08-27)

- **Umbrella issue**: [#3336](https://github.com/viamin/paid/issues/3336) — Execution runners epic (open; kept open, see Conclusion)
- **Closeout issue**: [#3661](https://github.com/viamin/paid/issues/3661)
- **Design home**: `docs/intent/container-runtime/container-runtime-design.md` (`Runner abstraction boundary`), [RDR-057](RDR-057-remote-execution-data-contract.md), [RDR-062](RDR-062-execution-network-policy-intent.md)
- **Follows**: the [RDR Closeout Checklist](closeout-checklist.md), adapted here for an issue-tree/LLD closeout rather than a single numbered RDR
- **Conclusion**: Partially Implemented. Ten of the twelve child issues (`#3337`–`#3344`, `#3346`, `#3347`) are closed and shipped. Two (`#3345`, `#3348`) remain open and their described scope is still genuinely unimplemented — no gap was found that isn't already covered by one of them, so **no new child issues are filed**. `#3336` stays open, tracked (not closed) by this audit.

## Historical numbering note

This issue tree (`#3336`–`#3348`) was filed under a provisional execution-runner
`RDR-054` label before that number was assigned to the now-implemented
[RDR-054: Prompt Assembly Service](RDR-054-prompt-assembly-service.md). Every
open issue in the tree (`#3336`, `#3345`, `#3348`) already carries a
"Historical numbering note" section stating this explicitly and pointing at
the real design home (`docs/intent/container-runtime/container-runtime-design.md`,
RDR-057, RDR-062). `docs/refactor/execution-runner-docker-coupling.md` carries
the same note. No open issue in the tree implies Prompt Assembly Service owns
this work — that acceptance criterion is already satisfied and required no
issue edits from this audit.

## Issue Tree Reconciliation

| # | Title | State | Shipped in |
|---|-------|-------|------------|
| [#3336](https://github.com/viamin/paid/issues/3336) | Epic: refactor agent execution, Docker as one runner backend | Open | — (umbrella; stays open, see Conclusion) |
| [#3337](https://github.com/viamin/paid/issues/3337) | Inventory Docker coupling | Closed | `docs/refactor/execution-runner-docker-coupling.md` |
| [#3338](https://github.com/viamin/paid/issues/3338) | Runner contracts and domain objects | Closed | `ExecutionRunners::Base`, `RunSpec`, `RunnerHandle`, `ExecutionResult` (`app/services/execution_runners.rb`, `app/services/execution_runners/base.rb`) |
| [#3339](https://github.com/viamin/paid/issues/3339) | Extract `LocalDockerRunner` | Closed | `app/services/execution_runners/local_docker_runner.rb` |
| [#3340](https://github.com/viamin/paid/issues/3340) | Migrate orchestration callers incrementally | Closed | `ExecutionRunners.resolve` call sites across Temporal activities |
| [#3341](https://github.com/viamin/paid/issues/3341) | Isolate networking policy | Closed | `ExecutionRunners::NetworkingPolicy`; superseded/extended by RDR-062 (Implemented) |
| [#3342](https://github.com/viamin/paid/issues/3342) | Isolate workspace/storage assumptions | Closed | `ExecutionRunners::WorkspaceStrategy`; three sub-items intentionally deferred (`CONTAINER-RUNTIME-012`/`-013`/`-014`, see [Deferred Workspace Items](#deferred-workspace-items-not-a-gap)) |
| [#3343](https://github.com/viamin/paid/issues/3343) | Abstract supporting services/sidecars | Closed | `ExecutionRunners::ServiceDeclaration`, five service/MCP/browser lifecycle methods on `Base` (Phase 1); Phase 2 activity consolidation explicitly deferred by design, not tracked as a gap |
| [#3344](https://github.com/viamin/paid/issues/3344) | Abstract logging/status/cancellation/cleanup | Closed | `ExecutionRunners::Base#status`/`#cancel`/`#cleanup`, `ExecutionStatus` |
| [#3345](https://github.com/viamin/paid/issues/3345) | Remove Docker concepts from AgentRun/Temporal | **Open** | Not yet shipped — see [Remaining Scope Verification](#remaining-scope-verification) |
| [#3346](https://github.com/viamin/paid/issues/3346) | Persist runner handle for recovery | Closed | `runner_handle` jsonb column, `AgentRun#reuse_or_reconcile_via_runner`, `RunnerHandle.from_record` |
| [#3347](https://github.com/viamin/paid/issues/3347) | Contract/shared tests for runner behavior | Closed | `spec/support/shared_examples/execution_runner_contract.rb` (`it_behaves_like "an ExecutionRunner implementation"`), `ExecutionRunners::ContractRunner` |
| [#3348](https://github.com/viamin/paid/issues/3348) | Document how to implement a second runner | **Open** | Not yet shipped — see [Remaining Scope Verification](#remaining-scope-verification) |
| [#3661](https://github.com/viamin/paid/issues/3661) | This closeout audit | Open | This document |

Note: the issue's dependency list (`Depends on #3345, #3347, #3348`) was
written before `#3347` closed. GitHub's own state is authoritative here — only
`#3345` and `#3348` remain as real blockers.

## What Shipped Under Later RDRs

The historical provisional-`RDR-054` workstream now lives across four
documents, all confirmed current as of this audit:

- **`docs/intent/container-runtime/container-runtime-design.md`** (`Runner
  abstraction boundary` section) — the living LLD for the runner contract,
  persisted-handle recovery, workspace strategy, and the supporting-services
  boundary. Already contains the historical-numbering note and links this
  closeout.
- **[RDR-057: Remote Execution Data Contract](RDR-057-remote-execution-data-contract.md)**
  — **Implemented** (2026-08-17, closed out via
  [#3417](https://github.com/viamin/paid/issues/3417), no remaining gaps).
  Ships `ExecutionInputManifest`/`ExecutionOutputManifest`.
- **[RDR-062: Provider-Neutral Execution Network Policy Intent](RDR-062-execution-network-policy-intent.md)**
  — **Implemented** (2026-08-13 via
  [#3403](https://github.com/viamin/paid/issues/3403), no remaining gaps).
  Ships the six-intent `NetworkingPolicy` vocabulary and
  `Base.supports_policy?` capability validation.
- **RDR-055** (egress allowlisting) — `NetworkingPolicy#egress_profile`
  propagation shipped as part of the container-runtime LLD (`:locked` /
  `:research` / `:open`), documented in the LLD's "Egress profile
  propagation" subsection.

[RDR-060: External Execution Resource Ledger](RDR-060-external-execution-resource-ledger.md)
and its umbrella [#3600](https://github.com/viamin/paid/issues/3600) touch the
same `ExecutionRunners` module (ownership tags, provisioning ledger,
reconciliation) but are a **separate, adjacent workstream** with their own
issue tree and closeout audits (most recently
[audit-report-2026-08-23-rdr-060.md](audit-report-2026-08-23-rdr-060.md)).
They are out of scope for `#3661` and are not double-counted here.

## Remaining Scope Verification

Both open issues were checked against the current codebase to confirm they
still describe real, unshipped work rather than stale scope.

### #3345 — Remove Docker concepts from AgentRun/Temporal

Still accurate. As of this audit:

- `AgentRun` still persists and directly manipulates `container_id` /
  `container_host` as primary state — `provision_container`
  (`app/models/agent_run.rb:2729`), `execute_in_container` (`:2762`),
  `cleanup_container` (`:2785`), `clear_container_id_if_unchanged!` (`:2839`)
  all read/write these columns directly, alongside (not replaced by) the newer
  `runner_handle` column.
- `RunAgentActivity` (`app/temporal/activities/run_agent_activity.rb`) still
  names its primary local variable `container_service` throughout (~15 call
  sites) rather than a runner-level name.
- This matches #3345's own "Relevant Existing Code" section verbatim — no
  divergence between the issue's stated scope and the current code.

### #3348 — Document how to implement a second runner

Still accurate. As of this audit:

- No dedicated runner-implementation guide exists anywhere in the repo
  (`find . -iname '*runner*.md'` outside `docs/intent/container-runtime/` and
  the RDRs returns nothing).
- The only second-runner-facing documentation today is inline: the LLD's
  `Runner abstraction boundary` section (architecture, not a how-to) and the
  YARD comments on `ExecutionRunners::ContractRunner`
  (`app/services/execution_runners/contract_runner.rb:1-32`), which document
  the in-memory test double, not a guide for a real second runner.
- This matches #3348's own scope — no divergence found.

## Deferred Workspace Items (not a gap)

`docs/intent/container-runtime/container-runtime-specs.md` marks
`CONTAINER-RUNTIME-012`, `-013`, and `-014` as `[D]` (deferred, per this
repository's LID status convention) rather than `[ ]` (gap). They cover
translating `WorkspaceStrategy#writable_dirs` into Docker tmpfs mounts,
runner-owned heartbeat monitoring, and pool-workspace management through the
runner — all originally surfaced while closing #3342. They are intentional,
already-documented deferrals with no obligation attached, not a residual gap
requiring a new follow-up issue. Neither #3345 nor #3348 claims this scope, so
this audit leaves them as `[D]` rather than filing a new issue for them.

## Gaps

None found beyond what `#3345` and `#3348` already describe. No new child
issues are filed by this audit.

## Recommendation

- Keep `#3336` **open**, tracked (not closed) by `#3661` — two real
  dependencies (`#3345`, `#3348`) remain unshipped.
- No new gap issues are needed; the existing open issues already have
  correct, current scope.
- Re-run this closeout once `#3345` and `#3348` land. At that point `#3336`
  and `#3661` can both close, since every other child issue is already
  shipped and no additional residual gaps were found.
