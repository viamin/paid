# RDR-075 M00 — RDR-073 Tool Handoff Validation — 2026-10-23

- **Draft design:** [PR #4308](https://github.com/viamin/paid/pull/4308)
- **Issue:** [#4327](https://github.com/viamin/paid/issues/4327) (M00: plan
  maintenance intent and validate the RDR-073 tool handoff)
- **Umbrella:** [#4326](https://github.com/viamin/paid/issues/4326) — tracked,
  not closed by this report
- **Result:** Critical assumption 1 is **validated** by the shipped RDR-073
  contract and its focused tests. Critical assumption 2 is **not yet
  validated**: the recorded analyzer commands ran in this checkout, not via
  `AgentRun#execute_in_execution_environment`, and no execution-environment
  sidecar request was recorded. The native CLI and sidecar acceptance criteria
  therefore remain open, owned by follow-up
  [#4604](https://github.com/viamin/paid/issues/4604). RDR-075 remains
  Draft; this report does not resolve the design's stated blocker, accept
  the design, or release implementation phases #4328–#4333.

This is a validation audit, not a closeout. It does not change RDR-073's
status (already final-accepted per
[the 2026-10-20 audit](audit-report-2026-10-20-rdr-073-epic-final-acceptance.md))
and does not promote RDR-075 out of Draft — acceptance remains subject to
human review under this repository's LID workflow stop-for-review discipline.

## Prerequisite check

Live GitHub state, checked 2026-10-23:

| Requirement | State |
| --- | --- |
| RDR-073 umbrella #4263 | Closed |
| RDR-073 closeout #4268 | Closed |
| RDR-073 epic final-acceptance audit | Complete ([2026-10-20](audit-report-2026-10-20-rdr-073-epic-final-acceptance.md)): all 4 phases shipped against every validation criterion, 103 examples passing at that audit |
| PR #4308 (RDR-075 design) | Open, unmerged, mergeable at check time; merged to main at 2026-10-23T23:34Z after this check — see addendum in "Recommended edits" |

RDR-073's prerequisite is satisfied, which is what unblocks this validation
(the draft's own "Blocked on" line names this report's outcome as the
remaining gate before implementation planning can proceed past #4327).

## Critical assumption 1 — issue-less attachment, matching, and endpoint behavior

**Claim to validate:** "RDR-073's completed attachment contract can expose
useful maintenance tools to issue-less runs."

**Finding: validated.** Source inspection of the full attachment pipeline
finds zero issue-coupling outside one explicitly optional rule condition:

- `MarketplaceEntries::Resolver#match_issue_labels_constraint`
  (`app/services/marketplace_entries/resolver.rb:167-172`) returns `true`
  (no constraint) when a rule does not declare
  `issue_labels_includes_any`. `#issue_labels`
  (`resolver.rb:184-186`) reads `agent_run.issue&.labels`, which safely
  evaluates to `[]` for an issue-less manual run — it does not raise.
- `#rule_matches?` (`resolver.rb:133-144`) combines that optional constraint
  with `match_repo_profile_constraint` for `languages_include_any` and
  `repo_files_include_any` (`resolver.rb:174-179`, reading
  `project.effective_repo_profile`) and `match_text_constraint` for
  `task_text_includes_any` (`resolver.rb:150-161`, reading
  `agent_run.custom_prompt`). All three work from project/run state that
  exists without an issue.
- `grep -rn issue app/services/marketplace_entries/renderer.rb
  app/services/marketplace_entries/attach_to_run.rb
  app/services/marketplace_entries/runtime_attachments.rb` returns no
  matches — the rendering, resolution, and runtime-snapshot-writing layers
  carry no issue dependency at all.
- `Containers::Provision#environment_variables`
  (`app/services/containers/provision.rb:3130`) exposes
  `PAID_TOOL_SIDECAR_ENDPOINTS` whenever `agent_run.tool_sidecar_endpoints`
  is present, with no issue-presence check.

This confirms the draft's own requirement text verbatim: "Matching must work
for manual runs without an issue; absent issue labels cannot prevent
language or explicit attachment selection from working" (RDR-075 draft,
Ownership boundary with RDR-073). A manual, issue-less maintenance run can
attach a tool through `languages_include_any`, `repo_files_include_any`, an
explicit attachment, or a task-text match; only a rule that itself scopes to
`issue_labels_includes_any` will correctly decline to match.

**Test evidence (run 2026-10-23):**

```
bundle exec rspec \
  spec/services/marketplace_entries/resolver_dbless_spec.rb \
  spec/services/marketplace_entries/resolver_spec.rb \
  spec/services/marketplace_entries/attach_to_run_spec.rb \
  spec/services/marketplace_entries/runtime_attachments_dbless_spec.rb \
  spec/services/marketplace_entries/renderer_dbless_spec.rb \
  spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb \
  spec/services/containers/provision_spec.rb \
  spec/services/pre_commit_requirements/evaluate_spec.rb
# 486 examples, 0 failures
```

## Critical assumption 2 — batch checkout access and invocation

**Claim to validate:** "Batch analyzers can analyze the pinned checkout and
return evidence within the existing execution boundary. RDR-073's
service-oriented image/port contract alone does not establish checkout
access or batch invocation. Validate one native CLI analyzer and one sidecar
interaction before finalizing the maintenance tool adapter design."

### Native CLI analyzer — shipped contract, pending native-environment validation

`AgentRun#execute_in_execution_environment` (`app/models/agent_run.rb:3041`)
→ `Containers::Provision#execute` (`app/services/containers/provision.rb:468`)
is the existing, shipped contract for running an arbitrary command inside
the run's own agent container — the same container that already has the
pinned checkout mounted at `/workspace` (`provision.rb:182`,
`prepare_workspace!`). `PreCommitRequirements::Evaluate#run_check`
(`app/services/pre_commit_requirements/evaluate.rb:72-85`) is a shipped
precedent: it calls `agent_run.execute_in_execution_environment(command,
stream: false)`, reads `result[:exit_code]`, and surfaces
`result[:stdout]`/`result[:stderr]` bounded by the command's own output —
exactly the "source access, invocation, exit-code handling" contract a
maintenance analyzer needs. `execute`'s `preparation:` parameter
(`provision.rb:468`, `apply_execution_preparation`/
`cleanup_execution_preparation` at `agent_run.rb` and
`provision.rb:1227-1269`) already materializes temporary files before a
command and removes them after, win or lose — the "bounded artifacts and
cleanup" half of the assumption.

This path has **no RDR-073 involvement at all**. It is the general
execution-environment contract every goal already uses, not a tool-sidecar
concern. Source and unit-test evidence establishes the contract, but cannot
establish that the provisioned agent image contains a selected analyzer or
that its mounted checkout, executor limits, streamed output, and cleanup
behave as expected in a live run.

**Host-only exploratory evidence (2026-10-23, read-only, no application files
modified):**

- Ruby/Rails: installed `debride` (a native CLI analyzer named in the
  draft's Research Findings) into an isolated `GEM_HOME`, then ran it
  directly against a checked-out directory:

  ```
  $ debride app/services/marketplace_entries/
  These methods MIGHT not be called:

  MarketplaceEntries::JsonParser
    parse_object!                       app/services/marketplace_entries/json_parser.rb:7-13 (7)

  Total suspect LOC: 7
  $ echo $?
  0
  ```

  Manual (prompt-only) verification: `grep -rn parse_object!
  app/ spec/` returns only the definition itself — no caller anywhere in the
  application or its tests. This is a genuine true positive, not a
  framework-callback or dynamic-dispatch false positive, and illustrates the
  draft's intended division of labor: the tool nominates a candidate; a
  semantic read confirms it before any recommendation.

- JS/TS: ran the project's own already-configured ESLint
  (`eslint.config.mjs`, `js.configs.recommended`) directly against a
  checked-out file:

  ```
  $ yarn eslint app/javascript/controllers/chat_controller.js
  Done in 0.26s.
  $ echo $?
  0
  ```

  (clean scan — a successful investigation with no findings, per the draft's
  "A completed investigation with no findings is successful"). To confirm
  the non-clean exit-code and bounded-diagnostic path, the same analyzer was
  run against a temporary fixture placed inside the configured glob and
  removed immediately after:

  ```
  $ yarn eslint app/javascript/controllers/zz_rdr075_validation_scratch.js
  1:10  error  'unused' is defined but never used      no-unused-vars
  2:7   error  'x' is assigned a value but never used  no-unused-vars
  5:10  error  'used' is defined but never used        no-unused-vars
  ✖ 3 problems (3 errors, 0 warnings)
  $ echo $?
  1
  ```

  (fixture deleted immediately after the run; `git status --porcelain
  app/javascript/controllers/` confirmed clean before continuing.)

Both runs demonstrate that these commands work in this checkout, with
structured output and deterministic exit codes. They do **not** demonstrate
the containerized `execute_in_execution_environment` mechanism: neither
command provisioned an `AgentRun`, and neither result is an execution artifact
from the agent image. They must not be used to resolve the native-analyzer
criterion.

**Required live evidence before resolving this criterion:** provision a fresh
`AgentRun` against its pinned checkout, invoke one selected native analyzer
through `agent_run.execute_in_execution_environment(..., stream: false)`, and
record the returned `stdout`, `stderr`, `exit_code`, image/check-out identity,
and successful run-container cleanup. Use a bounded, read-only target and
preserve the resulting artifact with this audit. This workspace has no Docker
client or Docker socket, so that live execution could not be performed here;
the criterion remains unvalidated rather than inferred from host commands.

### Sidecar interaction — RDR-073's contract is network-only; it does not grant checkout access

`Containers::McpProvisioner#create_hardened_tool_sidecar_container`
(`app/services/containers/mcp_provisioner.rb:389-430`) builds its Docker
`HostConfig` from `NetworkMode`, memory/CPU/PID resource limits, cap
drop/add, `SecurityOpt`, and `Tmpfs` only. There is no `Binds`,
`VolumesFrom`, or any other filesystem-sharing key. The companion spec file
(`spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb`)
asserts `HostConfig` shape and the per-run DNS alias but contains no
`Binds` assertion anywhere, consistent with the implementation never
setting one. `MarketplaceEntries::Renderer#inferred_attachment_strategy`
(`app/services/marketplace_entries/renderer.rb:57-61`) has exactly one
strategy for `entry_type == "tool"`: `"tool_sidecar"` — there is no
marketplace install path that places a binary inside the main agent
container's filesystem.

**Static finding:** the provisioner is designed to make a `tool_sidecar`
reachable from the agent container over the network, by its stable per-run DNS
alias and the port recorded in `PAID_TOOL_SIDECAR_ENDPOINTS`. Its creation
options do not grant filesystem access to the pinned checkout. RDR-073's
service-oriented image/port contract therefore does not by itself establish
checkout access or batch invocation for a sidecar. This is not a live
sidecar-interaction result: endpoint metadata and `HostConfig` inspection do
not exercise DNS, request routing, authentication, or sidecar lifecycle.

**Required live evidence before resolving this criterion:** provision a
representative allowlisted `tool_sidecar`, call its documented health or API
endpoint from the paired `AgentRun` through
`execute_in_execution_environment`, record the endpoint, response shape,
exit code, and both sidecar and run-container cleanup, then attach that
artifact to this report. No such request was made in this workspace because
it has no Docker client or Docker socket. The sidecar criterion remains
unvalidated.

**Provisional design direction — pending the two live validations.** The first
delivery's named analyzer candidates (Exhale, Knip, Debride, Vulture, PMD CPD
— RDR-075 draft, Research Findings) are native CLI tools, not network
services. The implementation plan should continue to target the existing
native-CLI execution contract, but must not assert that it is ready in the
agent image until the required native validation completes. The
`tool_sidecar` path remains scoped to tools that are inherently
network-callable services (the case RDR-073 was designed for); it is not yet
validated as a usable request path. Subject to that evidence, the maintenance
tool adapter design should:

1. Invoke native CLI analyzers (gem/npm-installable or already present in
   the agent runtime image) through
   `agent_run.execute_in_execution_environment`, the same contract
   `PreCommitRequirements::Evaluate` already uses, with the pinned checkout
   already present at the mount path.
2. Reserve `tool_sidecar` attachments for analyzers that are themselves
   network services and do not need full-repository filesystem access — for
   example, an API-style linter or an LSP-shaped service that receives
   bounded request payloads (file contents, diffs, symbol queries) over its
   documented endpoint, mirroring how `PAID_TOOL_SIDECAR_ENDPOINTS` is
   already consumed.
3. If a specific future recipe genuinely needs a sidecar with full
   checkout access (not required by any analyzer named in the current
   draft), that is a distinct RDR-073 extension — an optional read-only
   bind mount for `tool_sidecar` containers — and must be filed as upstream
   work with an explicit dependency before any phase that needs it is
   released. No such need exists in the current draft's scope, so no
   upstream issue is filed by this report.

## Critical assumption 3 — prompt-only vs. tool-assisted findings

The draft frames this as choosing recipes and reporting policy once tools
are integrated (#4330), not as a gate on this planning issue. This report
contributes one data point toward that later comparison rather than a full
study: the `debride` run above found a true-positive unused-method
candidate (`MarketplaceEntries::JsonParser#parse_object!`) that a
targeted `grep`-based prompt-only check could confirm but would not have
surfaced on its own without first being pointed at that method — consistent
with the draft's "Tool evidence identifies candidates; agents assess meaning"
division of labor. A fuller Ruby/Rails and JS/TS comparison on pinned
fixtures, as the draft's Validation section describes, belongs to #4330 once
an actual tool-assisted recipe exists to measure against; running it earlier
would mean comparing prompt-only review against ad hoc script output rather
than the shipped adapter contract.

## Recommended edits to PR #4308

This report does not edit `docs/rdrs/RDR-075-general-maintenance-runs.md`
directly — at check time that file lived on PR #4308's branch, and a
competing edit there would risk the exact "competing design PR" problem
the issue warns against. The PR's author or reviewer should, when next
revising PR #4308:

- Keep the **Blocked on** metadata line: critical assumption 2 remains open
  until a native analyzer and representative sidecar request have each run
  from an `AgentRun` execution environment with cleanup evidence.
- Update **Open Questions Before Finalization**, first bullet: RDR-073's
  image/port/DNS-alias contract is statically understood but awaits a live
  sidecar request. Native CLI analyzers are expected to use the existing
  `execute_in_execution_environment` contract, pending a native image run.
- The **Tool integration** section's "existing in-container tools" phrase
  should name `agent_run.execute_in_execution_environment` and make its use
  conditional on the required native-environment validation artifact.

**Addendum (2026-10-24, post-merge):** PR #4308 merged to main at
2026-10-23T23:34Z, so these edits no longer land on the PR's branch — they
land as follow-up changes to `docs/rdrs/RDR-075-general-maintenance-runs.md`
on main. The change resolving this PR's review applies them there directly:
the Open Questions and Tool-integration edits above are incorporated, and
the **Blocked on** line is kept with its pending-evidence ownership
retargeted from #4327 (which closes via this PR) to
[#4604](https://github.com/viamin/paid/issues/4604), the follow-up issue
that now owns the two live execution-environment validations.

## #4604 execution-environment revalidation — 2026-10-24

**Result: not executed; the required Docker-capable execution environment is
unavailable.** This follow-up rechecked the environment before attempting
either acceptance scenario. `docker`, `podman`, and `nerdctl` are absent;
neither `/var/run/docker.sock` nor `/run/docker.sock` exists; and no
`DOCKER_*` endpoint is configured. The Docker client cannot be installed as a
substitute for a Docker daemon, so provisioning an `AgentRun` here would not
produce the required live evidence.

| Required artifact | Attempt disposition | Evidence still required in a Docker-capable environment |
| --- | --- | --- |
| Native analyzer | Not started: no engine is available to provision the fresh run container. | A selected, read-only native analyzer invoked through `agent_run.execute_in_execution_environment(..., stream: false)`, with returned `stdout`, `stderr`, `exit_code`, pinned image/checkout identity, and successful run-container cleanup. |
| Sidecar interaction | Not started: no engine is available to provision the paired run and allowlisted `tool_sidecar`. | The documented endpoint called from the paired run through `execute_in_execution_environment`, with endpoint/response shape/exit code and successful sidecar and run-container cleanup. |

This is environment-capability evidence only. It is not a native analyzer or
sidecar artifact and does not change either criterion's status. No upstream
RDR-073 extension can be decided from an unprovisioned environment; retain
the existing direction that an extension is filed only if a completed live
validation identifies a checkout-dependent sidecar need.

## Disposition

This report resolves critical assumption 1 only. Critical assumption 2 remains
blocked on the two live execution-environment validations described above,
owned by [#4604](https://github.com/viamin/paid/issues/4604): because this
workspace had no Docker client or Docker socket, #4327 closes via the
resolving PR with its acceptance criterion 2 explicitly deferred to that
follow-up issue rather than silently satisfied — the concrete question and
recovery action #4327's execution scope requires, in Paid, not a silent
planning hold. RDR-075's **Blocked on** line and the `maintenance-runs`
arrow entry track #4604 as the evidence owner. This report does not:

- Accept RDR-075 — that remains a human review action. (PR #4308 has since
  merged to main; the merge carries the draft forward and is not
  acceptance.)
- Release implementation phases #4328–#4333 — their planning holds stay in
  place until the design and its LID artifacts (HLD update, maintenance
  LLD/EARS) are accepted and merged, per the draft's own Implementation Plan
  step 1 and this issue's acceptance criteria.
- Determine whether an upstream RDR-073 extension is needed — that decision
  follows the required native and sidecar execution evidence.

The #4604 revalidation on 2026-10-24 confirms that those two evidence
artifacts remain blocked specifically by the absence of a Docker-capable
execution environment. RDR-075 remains Draft, its `maintenance-runs` arrow
remains a draft-only mapping, and implementation phases #4328–#4333 remain
unreleased. Move the validation to a Docker-capable environment rather than
inferring live lifecycle behavior from static tests or host-only commands.

Companion artifacts drafted alongside this report (`docs/intent/maintenance-runs/`,
an HLD pointer) are reviewable drafts for the same pending human-review gate,
not accepted intent.
