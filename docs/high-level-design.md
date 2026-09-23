---
parent: root
prefix: PAID
---

# High-Level Design: Paid (Platform for AI Development)

> This is the LID high-level design — the top of the arrow of intent. It states
> the *why* and the *how* at the project level. Per-component detail lives in
> `docs/intent/` as low-level designs (LLDs) and EARS specs, added as the
> project grows. For deeper narrative on any topic below, see the linked
> long-form docs under `docs/`.

## Problem

Shipping software with AI coding agents is no longer bottlenecked by code
generation. Frontier models write plausible code on demand. The hard problems
have moved elsewhere:

- **Trust.** An agent that writes code is also an agent that can exfiltrate
  secrets, mutate state, and merge its own work. Running it safely means
  isolating it, scoping its credentials, and keeping a human at the merge gate.
- **Repeatability.** Each agent session starts with no memory of the last one.
  Prompt, model, and workflow choices made in one session do not carry forward
  unless they are captured as data.
- **Observability.** You cannot improve what you cannot measure. Token cost,
  iteration counts, success rates, and prompt effectiveness are invisible in an
  ad-hoc agent run.
- **Orchestration.** Turning a labeled issue into a merged PR is a multi-step
  workflow — plan, execute in an isolated container, open a PR, respond to
  review — that must be durable, resumable, and parallelizable.

Paid exists to make AI agents useful and safe for real software work by solving
these four problems together, as one system.

## Approach: Data Over Configuration

Paid's load-bearing bet is that **configuration is ephemeral, but data
endures**. Every decision point that could be hardcoded as configuration is
instead stored as data — prompts, model preferences, workflow patterns, quality
thresholds. Prompts are versioned entities with lineage and metrics, not
hardcoded strings; model choice is logged, not pinned; quality thresholds are
queried records, not constants. Over time the system learns what actually works
rather than what was assumed to work. See `docs/VISION.md` for the full thesis.

This is the through-line for every component: when a behavior could be a rule or
a record, Paid stores the record.

## Approach: Isolation by Default

Agents run in Docker containers built from a dedicated agent image
(`docker/agent/Dockerfile`). They receive scoped, short-lived credentials via a
secrets proxy rather than long-lived tokens; they operate in isolated
backend-selected workspaces (named-volume clones by default, legacy worktree
bind mounts only when explicitly requested); and they cannot interfere with
each other or reach the host.
Isolation is the precondition for running multiple agents in parallel and for
giving an agent broad permissions inside its container without broad
permissions on the system.

Specialized verification environments follow the same boundary. Apple project
code executes in disposable macOS guests, never on their host; guest egress is
resolved through the same Paid authority and network-policy path as agent
containers, with Paid-controlled DNS and proxy enforcement rather than guest
or repository-managed credentials.

## Approach: Human Final Say

Every code change goes through a pull request. By default a human merges each
one — human review is where quality is enforced, trust is built, and the system
learns from feedback. A project owner may opt a project into auto-merge
(`auto_merge_mode`: `off` by default, `dependabot_only`, or `all`), in which
case qualifying PRs merge without a per-PR owner click; that delegation is
explicit, scoped, and revocable. The Paid Review Bot (`paid-code-reviewer[bot]`)
adds an automated review pass, but the authority over whether a change lands
always rests with a human — exercised per-PR by default, or through the
auto-merge configuration when the owner has enabled it.

Paid's own reviewer follows the same human-final-say posture at the
comment-policy level: every preset on the project-level `review_depth`
control (`Focused`, `Balanced`, `Thorough`, default `Balanced`) enforces the
same evidence bar and the same "comments reserved exclusively for
actionable changes" rule. What the preset varies is **investigation depth**
— how far beyond the obvious correctness and security floor the reviewer
looks before deciding a comment is warranted — never the bar for posting
one. The effective preset is snapshotted onto each review run at creation
time so a later project change cannot retroactively alter an in-flight
review's behavior. See `docs/intent/review-depth-presets/`.

Human attention can also move earlier in the lifecycle. For approval-gated
features, the
`human_led_feature_factory` project operating mode ([RDR-066](rdrs/RDR-066-feature-intent-approval-lifecycle.md))
makes human approval of a feature's design the boundary before
implementation of that feature's work runs. Existing projects opt in; new
account onboarding proposes the mode as the default project posture with a
reviewable settings plan. The mode composes with — never replaces — the
project's independent auto-merge and TDD test-review choices.

For approval-gated features (RDR-066/RDR-067), the same authority applies at
the design level: an agent PR that drifts
from the human-approved design stops and asks a human. A one-PR exception can
never change approved product behavior, constraints, scope, or acceptance
criteria — product-level changes route through an amended RDR/LID design that
a human approves and merges before affected work resumes. See
`docs/intent/approved-intent-amendment/`,
`docs/intent/approved-intent-merge-guard/`, and, for the Inbox decision flow and
Mark approved action that records the initial approval, `docs/intent/feature-approval/`.

The planned confidence-driven policy in
[RDR-069](rdrs/RDR-069-question-centered-chat-exploration.md),
[RDR-070](rdrs/RDR-070-facet-confidence-and-clarification.md), and
[RDR-071](rdrs/RDR-071-confidence-driven-issue-delivery.md) makes contextual
chat the exploration workspace reached from Inbox. Agents produce aids suited
to the question and the person; diagrams are temporary tools, while answers
and evidence endure. Durable preferences require explicit user statements.

Under this policy, each material facet has separate numerical intent certainty
and technical confidence. An issue becomes actionable when each required score
passes independently configured thresholds (80/100 each by default), its
dependencies permit work, and its relevant design documents are merged. No
additional whole-feature approval click is required. The agent judges evidence
and relevance; code enforces policy, revisions, access and thresholds.

New findings create follow-up issues blocking feature completion, or update
unstarted issues. They do not pause in-flight work, including when feature-flag
isolation is impossible. Flags contain unfinished behavior where feasible;
completion verifies acceptance and dependencies before declaring activation
readiness. Normal CI, security, quality and release controls remain applicable.
Feature policy snapshots keep existing approval-gated work unchanged until
deliberately migrated. These are planned capabilities, not claims of shipping.

## Approach: All LLM Calls Through One Interface

Every LLM interaction in the application goes through the `agent_harness` gem —
never via raw HTTP to a provider API. This keeps provider-specific behavior
(error classification, rate-limit parsing, execution flags) in one place and
lets the control plane swap models and providers without scattered call sites.
The secrets proxy forwards authenticated requests from containers; it is
infrastructure, not an application-level LLM interface.

## Tenets

The operating principles that tie the approaches above to day-to-day work:

- **Human understanding is the planning output.** Prefer explanations and
  experiments fitted to the person's question over preserving every artifact
  produced during exploration.
- **Certainty belongs to scope.** Prefer explicit uncertainty per facet over
  a single feature-wide judgment of readiness.
- **Learn through forward work.** Confidence-driven delivery favors follow-up
  tasks and completion accounting over interrupting useful execution.

- **Data over configuration.** When a behavior could be a rule or a record,
  store the record.
- **Human final say.** The authority over whether a change lands rests with a
  human — exercised per-PR by default, or through explicit, revocable
  auto-merge configuration that delegates the per-merge decision under rules
  the owner defined.
- **Isolation by default.** Agents run in containers with scoped credentials,
  in isolated workspaces, unable to reach one another or the host.
- **Observable everything.** Token cost, iteration counts, success rates, and
  prompt effectiveness are tracked as data so the system can learn.
- **No silent stops.** When automation stops acting on a work item, the system
  surfaces that it stopped, why it stopped, and what clears it. A blocked state
  legible only in the database is a defect, not a quiet success.
- **One LLM interface.** All application-level LLM calls flow through
  `agent_harness`; fail loudly rather than papering over provider differences
  in the control plane.
- **Models are commodities.** No bet on a single provider; today's best model
  is tomorrow's baseline.
- **Fix forward.** Never skip hooks, disable linters, or ignore failing tests.
  Fix the underlying issue.

## Goals

1. **Turn labeled issues into merged PRs, end to end.** Watch, plan, execute in
   an isolated container, open a PR, and respond to review — as a durable,
   resumable workflow.
2. **Keep agents safe and isolated.** Scoped credentials, isolated container
   workspaces, and no path from an agent to a secret or to another agent's run.
3. **Make agent work observable and improvable.** Capture the data — tokens,
   cost, iterations, prompt lineage, quality — that turns guesswork into
   measurement.
4. **Stay portable across models and providers.** Swap the model or provider
   behind a component without rewriting call sites.
5. **Run in multiple deployment models.** Managed cloud and private deployment,
   with enterprise operations (SLO/SLA) and stable ecosystem extension points.

## Non-Goals

- **Not a replacement for developers.** Humans are the authority over changes;
  agents merge only on owner-configured auto-merge, which is off by default.
- **Not a prompt playground.** Paid manages production workflows, not
  experiments.
- **Not adversarial security review of downstream projects.** Paid runs agents
  the project's owner has authorized; securing the target codebase is that
  owner's responsibility.

## Target Users

Development teams who want to put AI coding agents to work on their GitHub
repositories with the safety, observability, and repeatability that ad-hoc
agent usage lacks — across managed-cloud and private-deployment models.

## Architecture

The system has four main layers. Full detail lives in `docs/ARCHITECTURE.md`
and `docs/AGENT_SYSTEM.md`; this section names the layers and how intent flows
between them.

1. **Rails control plane** — Hotwire UI, PostgreSQL, GoodJob background jobs,
   and the tenant/account model with row-level security. Thin controllers
   delegate to service objects (Servo, verb-noun naming). `db/schema.rb` is the
   canonical, self-documenting schema.
2. **Temporal orchestration** — durable workflows for agent execution.
3. **Container management** — Docker containers built from the agent image,
   using backend-selected isolated workspaces (named-volume clones by default,
   legacy bind mounts only for explicit compatibility paths); a secrets proxy
   supplies scoped credentials.
4. **Agent layer** — the `agent_harness` gem: a unified interface to CLI agents
   (Claude Code, Codex, Cursor, Gemini CLI, OpenCode, and others) and the
   single interface for all application-level LLM calls.

Apple verification workers extend the execution boundary without becoming agent
runners: the control plane sends source and provider-neutral manifests to a
disposable macOS guest, where a deterministic executor runs project build and
verification operations. The host lifecycle service never receives project
paths or commands; workflows become blocking only through digest-bound project
approval. Attempts queue behind operator-configured admission thresholds,
classify failures into a closed taxonomy that separates infrastructure results
from code defects, and enforce their approved lifecycle gates — required
verification stays pending until it runs or is waived, never silently skipped
and never fallen back to host execution. Structured results and screenshots
return through the artifact lane as private, retained project artifacts. See
`docs/intent/apple-verification-workers/` for the worker contract (profiles,
workflow revisions, attempts, waivers), `docs/intent/apple-guest-execution/`
for the immutable guest image catalog and guest protocol, and
`docs/intent/apple-verification-attempts/`,
`docs/intent/apple-verification-network-policy/`, and
`docs/intent/apple-verification-results/` for the attempt execution,
guest network, and results-and-artifacts contracts those attempts follow. The
lifecycle API is provider-neutral; its first implementation maps to Tart and
Softnet. See RDR-068.

Intent flows from the control plane (an issue is picked, a prompt is built, a
strategy is chosen) into orchestration (a durable workflow), into container
management (an isolated environment is provisioned), into the agent layer (the
agent executes against its isolated workspace and opens a PR), and back to the
control plane
(metrics, review, the human merge decision).

### Directory layout

```
app/
├── controllers/      # Thin controllers delegating to services
├── models/           # ActiveRecord: associations, validations, scopes
├── services/         # Business logic via Servo (organized by capability)
├── jobs/             # GoodJob jobs
└── views/            # ERB templates
docker/agent/         # The agent container image
docs/                 # Long-form docs; docs/intent/ holds the LID arrow
```

## Key Design Decisions

| Decision | Chosen | Rationale |
|---|---|---|
| Schema format | `schema.rb` + the `fx` gem | Self-documenting canonical schema; functions/triggers versioned in `db/functions/` and `db/triggers/`. |
| Tenant isolation | PostgreSQL row-level security on core tables | Enforced tenant scoping at the database, not just the application. |
| Change tracking | Logidze on configuration/access/financial tables | "Who changed what and when" where it matters; not on high-volume operational tables. |
| LLM interface | `agent_harness` for all calls | One place for provider behavior; swap models without scattered call sites. |
| Agent execution | Docker + isolated workspaces + secrets proxy | Isolation and scoped credentials by default. |
| Agent image tooling | Versions pinned from `agent_harness` contracts | Control plane and agent image stay in lockstep without separate pins. |
| Release management | release-please + Conventional Commits | Semantic releases from conventional commit headers. |

## LID adoption posture

This repository adopts LID in **Full** mode on a **going-forward** basis. The
HLD is the universal floor. LLDs and EARS specs are added as new features are
built and as existing subsystems are mapped over time; not all existing code is
traced yet, which is expected for brownfield adoption. When you build or change
a component, add (or update) its segment under `docs/intent/`.

## References

- `docs/ARCHITECTURE.md` — system design and technology stack
- `docs/AGENT_SYSTEM.md` — Temporal workflows and container management
- `docs/VISION.md` — the "data over configuration" thesis and guiding principles
- `docs/GLOSSARY.md` — domain terms
- `db/schema.rb` — canonical database schema with table and column comments
- `docs/rdrs/` — architectural decision records
- `CLAUDE.md` (canonical; `AGENTS.md` is a symlink) — operating workflow for agents
