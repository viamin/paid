---
parent: PAID
prefix: LLM-ROUTING
---

# Application LLM routing

Application text operations route through `Llm::Request` and `agent_harness`.
A run's effective runner and tier take precedence. Other operations use the
project owner's configured chat runner, then their default runner if enabled
for chat, then an enabled chat runner in saved priority order. Account work
uses the account's fallback owner; interactive global work uses the current
actor. Missing ownership or eligible configuration is an explicit error.

Existing user chat-runner and runner settings select the provider. Project
model and provider policy remains authoritative. No new vendor selector is
needed for each helper. Fallback follows user permission flags and configured
order within one shared timeout budget. Requests use the harness's explicit
execution boundary, bypassing its process-wide provider substitution. A default stored in settings is not proof the owner
has configured that vendor: routing must resolve a live, permitted Runner.
Post-push source-closure assessments use the owner's enabled fallback order
when the run's pinned runner cannot complete an isolated text request. The
fallback budget stays below the assessment activity deadline; disabled
fallbacks do not authorize another runner or billing mode.
An isolated text request skips a subscription runner with no managed credential
that is fresh or eligible for provider-owned refresh before provisioning a
container. An expired, unrevoked rotating credential with supported refresh
material remains a managed candidate until its serialized refresh attempt has
completed; failed, unsupported, revoked, or refresh-token-less credentials are
reported as requiring reconnection. Host-forwarded agent authentication is a
separate source and never proves isolated managed-audit readiness or imports a
host credential. When no usable alternative exists, routing reports the
credential configuration error immediately.
When concurrent managed records exist, an unusable newer expiry does not shadow
an older fresh credential at any isolated-text routing or readiness surface.

Text operations accept subscription and API-key runners. The existing chat-runner setting accepts owned runner identifiers, allowing
multiple configurations behind the same CLI to remain distinguishable. API credentials
come from the selected runner; unrelated host environment keys cannot change
billing mode. Managed subscription credentials need an isolated environment.
Every standalone text request uses a disposable text-only container; it does not
reuse a live run container, create a user-visible coding run, mount a
repository, or mount the Rails workspace. The container receives the selected
runner's materialized credentials through the existing container credential
path and invokes the harness with tools disabled. A `tools: none` option alone
is not evidence that a driver disables its tools; the container boundary is
therefore required even when the driver advertises tool control.
Each standalone container has a 1 GiB memory limit and the same combined
memory-and-swap limit, so requests cannot consume additional swap. CPU and
process limits remain enforced. The private `/home/agent` tmpfs is bounded at
256 MiB (mode 0700, uid/gid 1000), while `/tmp` remains bounded at 64 MiB
(#5211). Actual tmpfs consumption counts toward the container memory limit.
The memory allowance accommodates configured
CLI startup and structured acceptance prompts within the isolated boundary;
exhausting it never establishes a successful assessment.
Standalone application requests identify themselves to the harness as text
operations so provider-owned transport selection can use the API-key text
contract without changing coding-agent or subscription execution.
For an API-key Codex runner, the selected key is present in the in-memory
provider runtime when the harness chooses its transport. The disposable
executor removes that key from the Docker exec environment and retrieves it
inside the container through the scoped credential identity. A host key must
never substitute for the runner's selected credential.
Rotating managed credentials (Codex, OpenCode, OMP) reuse the provisioner's
refresh/lease/harvest lifecycle — `Runners::ManagedCredentialLifecycle` — so a
standalone request materializes a refreshed token and writes an in-container
rotation back into the canonical credential once before the container is deleted.
When a native rotation has been read but its canonical write cannot finish by
the candidate deadline, the executor transfers the captured rotation and its
lockfile lease to a recovery write. The request returns at its deadline; the
recovery keeps the lease until the atomic write completes or its fixed database
statement budget expires, and records a deferred harvest rather than dropping
or overwriting the captured credential. If recovery-thread admission fails,
the executor releases the transferred lease deterministically before surfacing
the admission failure, so no unowned lease can block later materialization.
The command, preparation, and prompt travel through an upgraded Docker exec
stdin connection, not as exec environment entries, because a single `execve`
environment string is capped near 128 KiB. The materializer checks that every
declared input byte arrived before starting the CLI. The transport waits for
process completion and checks the exit status before returning output. The container
root filesystem remains read-only. Docker's archive endpoint rejects writes
to read-only containers, including paths backed by tmpfs.
Harness preparation paths using `~/` resolve against the container user's home
before the materializer validates their allowed root and writes them. OpenCode
uses this form for its model configuration; treating the tilde as a literal
directory would make the CLI ignore the selected model.
An unavailable exit status, missing setup output, or Docker read timeout is a
transport failure, never success or a permanent configuration failure.
Caller environment entries are bounded per entry.
Embedding and interactive API chat keep their existing capability-specific
transports and settings. Provider identifiers inside those protocol adapters
are transport identities, not application-level provider preferences.

Structured callers include their response contract in the prompt and validate
JSON locally. They do not require a vendor's schema-only API. Provenance records
the actual response model rather than an assumed vendor model.

Acceptance requests retain a bounded route-attempt trace at the shared request
boundary. Each entry names the owned candidate runner, its resolved provider and
model once execution begins, ordinal, allocated and elapsed budget, phase,
normalized outcome, and correlation identifiers. A policy-, availability-,
credential-, or deadline-skipped candidate is explicitly `skipped`, never
represented as an execution failure. The selected terminal error is bound to
the attempt that produced it; configured-primary values are retained separately
as configuration context and never presented as observed failure provenance.
The trace is allowlisted and bounded before persistence, so it contains no
prompt, output, credentials, secret-bearing URL, HTTP body, or error message.

Isolated text commands use a process-group deadline before the container
watchdog, with a short cleanup margin. Their immutable orphan-sweep label uses
a fixed ten-minute lifetime from creation, so it remains a worker-death safety
net while a healthy executor reuses its container. Provisioning, command failure,
cancellation, timeout, and worker interruption all remove the disposable
container. Failed provisioning is terminal for that candidate and never falls
back to host execution. Timing out an assessment must not stop a live run's
container or make all retries fail.
Each route candidate receives an absolute monotonic deadline derived from the
single request deadline and its allocated slice. Provisioning, including Docker
network lookup or creation and upgraded exec creation, credential
materialization and refresh, command execution, and output handling consume
that same slice; an executor retains the short cleanup margin before it starts
a command. The command transport and container watchdog share the executable
allocation; they cannot consume the reserved cleanup time even when output
keeps streaming. Stop, delete, and credential cleanup retain the original
candidate deadline. Thus slow setup cannot obtain a fresh command timeout and a
spent request deadline cannot start another fallback. Cleanup is bounded and
best-effort: the executor attempts removal during the remaining candidate
deadline, and its immutable orphan-sweep label recovers a container when a
Docker cleanup call cannot finish. Managed credential lease acquisition and
the container read share that deadline; a read that cannot finish is deferred
and logged without extending the candidate lifetime. Once a native rotation
has been read, persistence that cannot finish by the candidate deadline moves
to a bounded recovery write retaining the lease. That handoff never extends
command execution or the candidate response lifetime.
The closeout assessment allows 60 seconds for CLI startup and reasoning,
within its 120-second activity budget including authentication and cleanup.
Background session summaries and error diagnosis use project-owner text routing because run cleanup can precede
those jobs. Decision drafting shares the same fallback permissions and timeout
budget as application text, including credential-specific circuit state.
Readiness reports a credentialed subscription as requiring isolation and an
uncredentialed subscription as missing configuration; it never claims that an
isolated route can execute a subscription until its managed credential is
active.

## Non-chat caller inventory

`spec/services/llm/request_caller_inventory_spec.rb` is the checked inventory
of all direct and wrapped application text callers. It prevents a new
background assessment from bypassing `Llm::Request`; the shared request service
therefore supplies ownership, runner permissions, model/privacy policy,
credential mode, provenance, retries, and disposable-container cleanup.

| Execution context | Callers |
| --- | --- |
| Account-only background work | `AgentRunPatterns::Diagnose` |
| Audit-run semantic scope discovery | `LayeredVerification::UnmappedMaterial` injects `Llm::Request` with the audit's `agent_run` and a bounded timeout. The text assessment uses disposable-container isolation; the audit run does not authorize host execution. |
| Project-only review, knowledge, design, evidence, and evolution work | `AgentRuns::DiagnoseError`, `Automation::AssessBoundedScope`, `DesignAmendments::ImpactReview`, `FeatureIntents::{AssessDesignArtifactCandidates,AssessFacet,CriteriaClarityReview}`, `IntentConformance::ReviewerLlm`, `Issues::PartialCompletionAssessment`, `Knowledge::{ContextIntake::GenerateQuestions,Decisions::Draft}`, `PartialCloseouts::{AssessEvidence,ValidateSubmittedEvidence}`, `PromptEvolution::Mutate`, `Reviews::Verification::LlmSession`, `StrategyEvolution::Mutate`, `StyleGuideEvolution::Mutate`, `StyleGuides::{Compress,Extract}`, and the analyze-issue, analyze-knowledge-gaps, and decompose-feature activities. |
| Live-run optional work | `ConflictRepairs::AssessScope`, `CycleAnalyses::Analyze`, `Features::ClarifyingQuestions::Analyze`, `Models::MetaAgentSelector`, and `Screenshots::DeriveHints`. A live run never authorizes host execution. `CycleAnalyses::Analyze` dependency-injects `Llm::Request`; the inventory treats that supported call shape like a literal request call. |
| Post-run / cleanup-race work | `Llm::{AnalyzePartialCloseout,AssessNoOutputDisposition,GenerateAgentUpdateSummary,GenerateIssueTitle,GeneratePrDescription,GenerateSessionSummary}`, `AgentRuns::DiagnoseError`, `Knowledge::SessionSummaries::Capture`, `PartialCloseouts::ReconcileLegacy`, and the assess-source-closure, complete-existing-PR-run, create-GitHub-issue, create-pull-request, handle-no-output-issue-run, reconcile-partial-closeout, and run-acceptance-audit activities. They continue through the disposable text container after a run’s container has been removed. The inventory discovers every `Llm::*` request wrapper from its `Request` reference, then source-checks every wrapper `.call` consumer. |

## Decisions

| Decision | Rationale | Alternative |
| --- | --- | --- |
| Reuse existing runner preferences | Keeps credentials, model policy and provider selection together | Separate provider preference per helper fragments configuration |
| Validate JSON locally | Subscription runners can perform text assessments | Requiring schema APIs excludes otherwise capable runners |
| Reserve cleanup from candidate deadline | Prevents setup from receiving a second full execution allocation while retaining bounded removal and orphan-sweep recovery | Give cleanup unbounded time after execution |
| Explicit failure without ownership | Prevents billing another tenant or silently using host credentials | Global vendor fallback hides incomplete configuration |
