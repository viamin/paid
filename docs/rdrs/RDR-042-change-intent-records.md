# RDR-042: Change Intent Records for the Knowledge Base

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-06-27
- **Status**: Partially Implemented
- **Type**: Process + Architecture
- **Priority**: Medium
- **Related Issues**: #3162 (closeout), #2695 (phase 1), #2696 (phase 2), #2697 (original phase 3), #2740 (phase 1 implementation), #2739 (phase 2 implementation), #2761 (phase 3 implementation claim)
- **Related Tests**: Knowledge artifact integration tests, context bundle tests, decision record collector tests

## Implementation Status

Partially implemented as of 2026-08-04.

Shipped behavior:

- Phase 1 shipped: the `change_intents` table/model, project-scoped policy, lifecycle services, knowledge-artifact sync, collectors, and context-bundle section are present.
- Phase 2 shipped: `record_change_intent` exists as a post-dispatch write tool, the chat flow supports draft approval/denial, and the chat system prompt instructs the model to offer a CIR when the user gives a non-obvious constraint or rejects a reasonable alternative.
- Phase 3 shipped in part: external agents can retrieve CIRs through `search_intents` and `get_intent`.

Remaining gap:

- Phase 3 issue enhancement is still missing. `EnhanceIssueActivity` currently asks clarifying questions, but it does not create or surface linked CIR drafts from issue bodies. See [audit-report-2026-08-04.md](audit-report-2026-08-04.md).

The original RDR text below is kept as the architectural plan. The closeout above records what actually shipped and where implementation still diverges.

## 2026-08-04 Reconciliation

The original RDR and its phase issues assumed the whole feature was still ahead of implementation. That is no longer true.

- Closed issues [#2695](https://github.com/viamin/paid/issues/2695) and [#2740](https://github.com/viamin/paid/issues/2740) correspond to shipped model and knowledge-pipeline work.
- Closed issues [#2696](https://github.com/viamin/paid/issues/2696) and [#2739](https://github.com/viamin/paid/issues/2739) correspond to shipped chat creation flow work.
- Closed issues [#2697](https://github.com/viamin/paid/issues/2697) and [#2761](https://github.com/viamin/paid/issues/2761) overstate current Phase 3 completeness: external lookup tools shipped, but issue-enhancement CIR drafting does not currently exist in `EnhanceIssueActivity`.

As a result, RDR-042 should no longer be marked "Accepted" in the index. It is partially implemented until the issue-enhancement gap is tracked and shipped.

## Problem Statement

Paid captures two kinds of decisions:

1. **RDRs**: Prospective architectural decisions, researched and documented before implementation.
2. **DecisionRecords**: Retrospective implementation decisions, auto-drafted from completed agent run diffs via `Knowledge::Decisions::Draft`.

Neither captures *directional intent* — why a human directed an agent a particular way during an interactive session. When a user tells the chat agent "use sliding window, not token bucket" or "follow the auth middleware pattern," that reasoning:

- Is not captured in the knowledge base
- Evaporates when the chat session is archived or expires
- Is invisible to future agents working on the same project
- Cannot be retrieved via `Knowledge::Search` or injected into context bundles

We need a lightweight artifact that captures the human's directional intent at the point it's given, stores it in the knowledge base, and surfaces it to future agents.

## Context

### Background

The [Change Intent Record (CIR) proposal](https://blog.bryanl.dev/posts/change-intent-records/) from Bryan Liles identifies a documentation gap created by AI-assisted development: code captures *what* was built, commit history captures *when*, ADRs capture *why* architecturally — but none capture *why the human instructed the agent that way*.

CIRs are designed as a lightweight, ADR-inspired format (intent, behavior, constraints, decisions, date) that sits between commits and ADRs: closer to the work than architecture, but more durable than conversation.

### Technical Environment

- **Knowledge base**: Existing artifact/chunk/embedding pipeline (`KnowledgeArtifact`, `KnowledgeChunk`, Qdrant vectors)
- **Decision records**: `DecisionRecord` model with status lifecycle (draft/active/superseded/reverted), auto-drafted from agent runs
- **Chat system**: `ChatSession`/`ChatMessage` with full conversation persistence, MCP tool dispatch, human-in-the-loop approval
- **Context intake**: Structured questionnaire wizard that feeds `business_context` artifacts
- **Context bundles**: `Knowledge::ContextBundle::Build` assembles artifact types into agent prompt context

## Research Findings

### Investigation Process

1. Analyzed the CIR proposal and compared with existing Paid decision-capture mechanisms
2. Mapped the four touchpoints where directional intent is given (chat, issues, context intake, external agents)
3. Evaluated whether DecisionRecord could be extended vs. needing a new model
4. Assessed integration cost with existing knowledge infrastructure

### Key Discoveries

**CIR vs. DecisionRecord distinction:**

| Dimension | DecisionRecord | CIR |
|-----------|---------------|-----|
| Source | Agent run diff + summary (`agent_summary_with_stderr_fallback`) | Human direction (chat message, issue comment) |
| Generation | Auto-drafted by LLM after agent run completes | Drafted by LLM from direction, reviewed by human |
| Subject | "What the code decided" (implementation decisions) | "Why I told the agent to do it that way" (directional intent) |
| Key fields | title, summary, context, decision, consequences | intent, behavior, constraints, decisions_made |
| Persistence trigger | Agent run completes | Human gives a non-obvious constraint or rejects a reasonable alternative |
| LLM call cost | 1 call per agent run (fixed) | 1 call per CIR-worthy direction (ad hoc) |

The two are structurally different and should coexist as distinct artifact types. Extending DecisionRecord with a `type` discriminator would complicate its immutability model (`MUTABLE_FIELDS`) and conflate two different persistence triggers.

**Existing infrastructure that CIRs can reuse:**

- `KnowledgeArtifact` / `KnowledgeChunk` — no new tables needed for search
- `Knowledge::Search` — semantic + lexical retrieval works on any artifact type
- `Knowledge::ContextBundle::Build` — section-based assembly with priority ordering
- `Knowledge::Collectors::DecisionRecordCollector` — can generalize to index both types
- `Knowledge::Decisions::Supersede` — lifecycle logic is reusable
- Chat MCP tool dispatch — `Tools::Registry` supports adding new tools

**Four touchpoints where directional intent leaks:**

1. **Chat (popup / workspace)**: Human types a constraint that shapes the agent's approach. The raw `ChatMessage` persists, but the distilled intent is unstructured and unindexed.
2. **Issue descriptions**: Human writes constraints in the issue body. Issue text is indexed, but the *reasoning behind the constraints* (rejected alternatives) is not captured separately.
3. **Context intake / open questions**: Captures business-level knowledge (what the project *is*), not change-level direction (why this particular constraint exists).
4. **External agents**: An agent using Paid's conventions via MCP tools (`search_code`, `get_project`) has no path to discover past directional decisions.

**Judgment heuristic (from CIR proposal):**

Only write a CIR when you rejected a reasonable alternative that a future reader might try. If the direction is obvious from the code or the constraint is self-evident, skip it. More CIRs means more noise. This aligns with the existing RDR principle of proportion.

## Proposed Solution

### Approach

Introduce `ChangeIntent` as a lightweight model that stores CIR-structured records, indexed as `change_intent` knowledge artifacts. The primary creation path is the chat system via a new MCP tool. Retrieval is automatic via the existing knowledge search and context bundle pipeline.

### Technical Design

**Model:**

```ruby
# app/models/change_intent.rb
class ChangeIntent < ApplicationRecord
  STATUSES = %w[draft active superseded].freeze
  MUTABLE_FIELDS = %w[status superseded_by_id updated_at].freeze

  belongs_to :project
  belongs_to :chat_session, optional: true
  belongs_to :issue, optional: true
  belongs_to :superseded_by, class_name: "ChangeIntent", optional: true

  has_many :supersedes, class_name: "ChangeIntent",
    foreign_key: :superseded_by_id, inverse_of: :superseded_by

  validate :enforce_immutability, on: :update

  validates :title, presence: true
  validates :intent, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
end
```

```
change_intents
  project_id          bigint, NOT NULL, FK
  chat_session_id     bigint, optional, FK
  issue_id            bigint, optional, FK
  title               text, NOT NULL
  intent              text, NOT NULL       — what were you trying to accomplish?
  behavior            text                 — given/when/then scenarios
  constraints         text                 — boundaries that shaped implementation
  decisions_made      text                 — what alternatives were rejected and why
  superseded_by_id    bigint, optional, FK (self-referencing)
  status              varchar, default "draft", NOT NULL
  created_at          timestamp, NOT NULL
  updated_at          timestamp, NOT NULL
```

**Status lifecycle:**

```
draft ──► active ──► superseded
              │
              └──► (reverted — optional, only if human retracts)
```

**Knowledge artifact integration:**

```
ChangeIntent created
  → KnowledgeArtifact (artifact_type: "change_intent")
    → KnowledgeChunk per CIR section (intent, behavior, constraints, decisions_made)
      → Embedded → Qdrant
      → Searchable via Knowledge::Search
      → Included in context bundles
```

The `DecisionRecordCollector` is generalized to `DecisionCollector` that indexes both `decision_record` and `change_intent` artifacts.

**Context bundle section:**

The `Knowledge::ContextBundle::Build` section order gains a new entry:

```
section_order:
  - business_context
  - documents
  - routes
  - symbols
  - schema
  - hotspots
  - decisions        # ← existing DecisionRecord artifacts
  - change_intents   # ← new, lower priority than decisions
  - stats
```

`change_intents` sit below `decisions` in priority — they're softer, more subjective guidance.

**Chat creation flow (MCP tool):**

A new MCP tool `record_change_intent` is available in chat sessions:

1. When the agent detects a CIR-worthy direction during conversation (constraint given, alternative rejected), it prompts: "This seems like a non-obvious constraint. Create a Change Intent Record?"
2. On approval, the agent drafts a CIR from the conversation context and calls `record_change_intent`
3. The tool creates a `ChangeIntent` record in `draft` status
4. The human reviews and approves/edits via the chat UI (same approve/deny pattern as write tool confirmation)
5. On approval, status transitions to `active` and knowledge artifacts are created

**Issue-level creation (future):**

During issue enhancement (`EnhanceIssueActivity`), if the issue body contains constraint-heavy language, the system can offer to create a CIR. This is Phase 3.

### Decision Rationale

1. **New model over extending DecisionRecord**: DecisionRecord enforces immutability on non-status fields and is tightly coupled to agent runs. CIRs have a different persistence trigger (human direction, not agent run completion), different required fields, and a different lifecycle. A separate model is cleaner.
2. **Knowledge artifact reuse**: The existing ingestion, embedding, and search pipeline handles any new artifact type. No new infrastructure.
3. **MCP tool as primary creation path**: Chat is where directional intent is most frequently expressed. A tool call is the lowest-friction way to capture it.
4. **Human-in-the-loop review**: Auto-drafted CIRs start as `draft` and require human approval. This prevents noise and ensures accuracy.
5. **Supersede lifecycle**: Directional intent evolves. The supersede chain lets agents trace how constraints changed over time.

### Implementation Example

```
# Chat exchange:
User: "Add rate limiting to the API. Use sliding window, not token bucket."
Agent: "Got it. Sliding window with Redis, following the auth middleware pattern."
       "This is a non-obvious constraint — I'll note that token bucket was rejected
        in favor of sliding window for smoother limiting. Create a CIR?"

User: "Yes"

Agent: [calls record_change_intent tool with draft payload]

# Result stored as:
# title: "Sliding window rate limiting over token bucket"
# intent: "Prevent abuse of public API endpoints with smooth per-user limiting"
# constraints: "Use existing Redis, follow auth middleware pattern"
# decisions_made: "Rejected token bucket (too complex for our traffic patterns)"
```

## Alternatives Considered

### Alternative 1: Extend DecisionRecord with type discriminator

**Description**: Add a `record_type` column to `DecisionRecord` (`"implementation"` vs. `"direction"`) and modify `Knowledge::Decisions::Draft` to handle both.

**Pros**:

- No new model, migration, or controller
- Reuses existing supersede logic, links, and collector
- Single search namespace for all decisions

**Cons**:

- DecisionRecord enforces immutability on non-status fields; CIR fields (intent, behavior) would be different from DecisionRecord fields (summary, context, decision)
- Persistence trigger is different (agent run completion vs. human direction in chat) — conflating the two makes the codebase harder to reason about
- `DecisionRecord` has a unique index on `agent_run_id` — CIRs don't always have an agent run
- Current LLM prompt for drafting (`knowledge.draft_decision`) generates ADR-lite fields; a CIR prompt would generate different fields, requiring conditional logic in Draft

**Reason for rejection**: The models serve different purposes and have different constraints. A shared table forces compromises on validation, immutability, and querying. A separate model is the cleaner design.

### Alternative 2: Store CIRs as unstructured chat metadata only

**Description**: Instead of a dedicated model, store CIR data as JSON in `ChatSession.metadata` and rely on chat message search for retrieval.

**Pros**:

- Zero new infrastructure
- No migration needed

**Cons**:

- Not indexed in the knowledge base — invisible to `Knowledge::Search` and context bundles
- No semantic search (chat messages aren't embedded as searchable artifacts)
- No lifecycle management (no active/superseded, no supersede chain)
- Not accessible to external agents via MCP tools
- Metadata is opaque — no structured querying by intent, constraints, etc.

**Reason for rejection**: Fails the core requirement of making directional intent discoverable by future agents.

### Alternative 3: Capture everything, no judgment heuristic

**Description**: Create a CIR for every direction, constraint, or preference expressed in chat.

**Pros**:

- Complete capture, no judgment errors

**Cons**:

- Noise drowns signal — future readers can't distinguish critical constraints from casual preferences
- Agent context budget is consumed by low-value artifacts
- Human review burden scales with every interaction

**Reason for rejection**: The CIR proposal's judgment heuristic ("only write when you rejected a reasonable alternative") is essential. Not every direction warrants a CIR.

## Trade-offs and Consequences

### Positive Consequences

- **Closes a real gap**: Directional intent is captured before it evaporates
- **Rides existing infrastructure**: No new pipelines, embeddings, or search modes
- **Dual retrieval**: Semantic search across CIR content + lexical search across structured fields
- **Cross-session memory**: A constraint from one chat session surfaces in a later session's context bundle
- **External agent visibility**: MCP tools expose past directional intent to any agent integrating with Paid

### Negative Consequences

- **Model maintenance**: New model means new migration, controller, policy, tests
- **Review burden**: Humans must review auto-drafted CIRs (mitigated: draft → active requires approval; drafts can be deleted)
- **Context budget pressure**: `change_intent` artifacts consume token budget in context bundles (mitigated: lowest priority section, dropped first when over budget)

### Risks and Mitigations

- **Risk**: CIRs become noise — humans approve everything without review
  **Mitigation**: The judgment heuristic is built into the creation flow (agent offers, human must explicitly approve). The `draft` status is not indexed as `active`; only approved CIRs enter the knowledge base.

- **Risk**: CIRs pile up and overwhelm context bundles
  **Mitigation**: Lowest-priority section in context bundles. Capped by token budget. Superseded CIRs get lower relevance weight in search.

- **Risk**: CIRs duplicate what's already in DecisionRecords
  **Mitigation**: They capture different sides of the same coin — DecisionRecord: implementation decision; CIR: directional intent. Both are useful separately.

- **Risk**: Chat performance impact from CIR detection logic
  **Mitigation**: Detection is a lightweight LLM prompt in the agent loop, not an additional API call. The existing `MAX_TOOL_ITERATIONS` cap applies.

## Implementation Plan

### Phase 1: Model + Knowledge Pipeline

**Prerequisites:**

- [ ] Knowledge artifact infrastructure is operational (exists)

**Step 1: Generate migration**

```bash
rails generate migration CreateChangeIntents
```

Create `change_intents` table with columns as specified above. Add foreign keys to `projects`, `chat_sessions`, `issues`. Add unique index on `(project_id, title)` or rely on IDs. Add index on `status`.

**Step 2: Create model**

`app/models/change_intent.rb` — status lifecycle, immutability, associations. Follow `DecisionRecord` patterns for validation and state transitions.

**Step 3: Add artifact type**

Add `"change_intent"` to the artifact type enum/vocabulary in `KnowledgeArtifact`. No migration needed — `artifact_type` is a string column.

**Step 4: Generalize decision collector**

Rename `Knowledge::Collectors::DecisionRecordCollector` to `Knowledge::Collectors::DecisionCollector` (or add a second collector). Index `change_intent` artifacts alongside `decision_record` artifacts.

**Step 5: Add context bundle section**

Add `change_intents` section to `Knowledge::ContextBundle::Build` section order, below `decisions`.

**Files to create/modify:**

- `db/migrate/TIMESTAMP_create_change_intents.rb`
- `app/models/change_intent.rb`
- `app/services/knowledge/collectors/decision_collector.rb` (generalized)
- `app/services/knowledge/context_bundle/build.rb` (add section)
- `app/services/knowledge/artifact_store.rb` (if type validation)

### Phase 2: MCP Tool + Chat Flow

**Prerequisites:**

- [ ] Phase 1 complete

**Step 1: Create MCP tool**

`app/mcp/tools/record_change_intent.rb` — accepts title, intent, behavior, constraints, decisions_made. Creates `ChangeIntent` in `draft` status. Authorized via Pundit — user must have write access to the project.

**Step 2: Wire detection in agent loop**

Modify `ChatSessions::AgentLoop` to detect CIR-worthy exchanges. The detection is a prompt instruction in the system prompt: "When the user gives a non-obvious constraint or rejects a reasonable alternative, ask if they'd like to create a Change Intent Record." If yes, call `record_change_intent` and present for approval.

**Step 3: Approval UI**

Reuse the existing write tool confirmation pattern (approve/deny) in the chat UI. On approval, transition CIR to `active`. On denial, delete or leave as `draft`.

**Files to create/modify:**

- `app/mcp/tools/record_change_intent.rb`
- `app/controllers/change_intents_controller.rb` (optional, for edit UI)
- `db/seeds/prompts.rb` (detection prompt)
- `app/services/chat_sessions/agent_loop.rb` (detection logic)

### Phase 3: Auto-Detection in Other Flows

**Prerequisites:**

- [ ] Phases 1 and 2 complete

**Step 1: Issue enhancement**

Detect constraint-heavy language in issue bodies during `EnhanceIssueActivity`. Offer to create a CIR linked to the issue.

**Step 2: External agent exposure**

Add MCP tools `search_intents` and `get_intent` for external agents to discover past directional decisions.

### Dependencies

- Knowledge artifact/chunk/embedding infrastructure (exists)
- Chat system with MCP tool dispatch (exists)
- Pundit authorization (exists)

## Validation

### Testing Approach

1. Unit tests for `ChangeIntent` model (validations, status transitions, immutability)
2. Unit tests for `record_change_intent` MCP tool (authorization, creation, error handling)
3. Integration tests for knowledge artifact creation on status transition
4. Integration tests for context bundle inclusion
5. Chat system tests for detection flow (mock the detection prompt response)

### Test Scenarios

1. **Scenario**: User gives a constraint in chat, agent detects CIR-worthy exchange
   **Expected Result**: Agent asks to create CIR, user approves, CIR saved as `active`, artifact created

2. **Scenario**: Agent creates CIR, user denies
   **Expected Result**: CIR stays `draft` or is deleted, no artifact created

3. **Scenario**: CIR is superseded by a later CIR
   **Expected Result**: Original goes to `superseded`, new CIR becomes `active`, supersede chain recorded

4. **Scenario**: CIR retrieved via knowledge search
   **Expected Result**: Semantic search returns CIR content, lexical search matches on title/intent

5. **Scenario**: Context bundle includes CIRs
   **Expected Result**: `change_intent` section appears in bundle, below `decisions`, within token budget

6. **Scenario**: Chat direction with obvious constraint (no CIR warranted)
   **Expected Result**: No CIR offered, no noise introduced

### Performance Validation

- CIR creation latency: MCP tool call < 500ms
- Knowledge search with CIRs: same latency as existing artifact search (no new indexes needed)
- Context bundle with CIR section: within existing token budget enforcement

### Security Validation

- MCP tool enforces Pundit authorization (project write access)
- CIRs are project-scoped, never cross-tenant
- No sensitive content in CIRs (mitigated: human review step)

## References

### Requirements & Standards

- [Change Intent Records: The Missing Artifact in AI-Assisted Development](https://blog.bryanl.dev/posts/change-intent-records/) — Bryan Liles, 2026-01-31
- RDR-021 Knowledge Base Architecture — Existing knowledge infrastructure
- `docs/KNOWLEDGE_BASE.md` — Knowledge base design documentation

### Dependencies

- `app/models/decision_record.rb` — Status lifecycle pattern to follow
- `app/services/knowledge/decisions/draft.rb` — Decision drafting pattern
- `app/services/knowledge/collectors/decision_record_collector.rb` — Collector to generalize
- `app/services/knowledge/context_bundle/build.rb` — Context bundle section order
- `app/mcp/tools/registry.rb` — Tool registration pattern

### Research Resources

- CIR template: Intent, Behavior, Constraints, Decisions, Date
- Existing DecisionRecord: title, summary, context, decision, consequences, tags, commit_sha_start/end

## Notes

- The `change_intent` artifact type could eventually be indexed by a `ChangeIntentCollector` that also generates embedding from structured fields (not just raw chunk content). For Phase 1, plain chunk embedding suffices.
- CIRs from external agents (non-Paid agents using Paid's convention MCP tools) should support `actor_type` / `actor_id` provenance tracking, reusing the pattern from `KnowledgeAuditEvent`.
- If CIRs prove valuable for chat, consider backfilling historical chat sessions: an LLM job scans archived sessions for CIR-worthy directions and offers them as drafts. Low priority.
- The supersede chain could eventually feed into the knowledge evolution workflow (`KnowledgeEvolutionJob`) to detect stale directional constraints.
