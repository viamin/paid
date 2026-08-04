# RDR-042 Audit Report — 2026-08-04

## Summary

RDR-042 is no longer accurately described as "accepted, not implemented." As of Tuesday, August 4, 2026, the repository ships the core Change Intent Record (CIR) model, lifecycle, authorization, knowledge-artifact integration, chat write-tool flow, and external lookup tools. The remaining gap is narrower: issue enhancement does not currently auto-detect and draft CIRs from constraint-heavy issue bodies, even though Phase 3's original issue was closed.

## GitHub State

- Closeout issue [#3162](https://github.com/viamin/paid/issues/3162) is open.
- Original implementation issues [#2695](https://github.com/viamin/paid/issues/2695), [#2696](https://github.com/viamin/paid/issues/2696), and [#2697](https://github.com/viamin/paid/issues/2697) are closed.
- Implementation follow-up issues [#2740](https://github.com/viamin/paid/issues/2740), [#2739](https://github.com/viamin/paid/issues/2739), and [#2761](https://github.com/viamin/paid/issues/2761) are closed.

## What Shipped

### Phase 1: model and knowledge pipeline

- `change_intents` table, foreign keys, indexes, and RLS policies are present in `db/schema.rb`.
- [`ChangeIntent`](../../app/models/change_intent.rb) exists with project/chat/issue associations, immutable content fields, and lifecycle methods for `activate!`, `supersede!`, and `revert!`.
- [`ChangeIntentPolicy`](../../app/policies/change_intent_policy.rb) enforces project-scoped authorization.
- knowledge indexing exists through [`Knowledge::Collectors::ChangeIntentCollector`](../../app/services/knowledge/collectors/change_intent_collector.rb), [`Knowledge::Collectors::DecisionCollector`](../../app/services/knowledge/collectors/decision_collector.rb), and [`ChangeIntents::SyncKnowledgeArtifact`](../../app/services/change_intents/sync_knowledge_artifact.rb).
- context bundles include CIRs via [`Knowledge::ContextBundle::Build`](../../app/services/knowledge/context_bundle/build.rb).

### Phase 2: chat creation flow

- the `record_change_intent` MCP write tool exists in [`app/mcp/tools/record_change_intent.rb`](../../app/mcp/tools/record_change_intent.rb).
- post-dispatch human approval is implemented through `Tools::Registry.post_dispatch_confirmation?`, `ChatSessions::AgentLoop`, and `ChatSessions::ResolveToolCall`.
- approval activates and indexes the CIR; denial deletes the draft via [`ChangeIntents::Activate`](../../app/services/change_intents/activate.rb) and [`ChangeIntents::DiscardDraft`](../../app/services/change_intents/discard_draft.rb).
- the chat system prompt explicitly tells the model to offer a CIR when the user provides a non-obvious constraint or rejects a reasonable alternative in [`ChatSessions::BuildSystemPrompt`](../../app/services/chat_sessions/build_system_prompt.rb) and [`db/seeds/prompts.rb`](../../db/seeds/prompts.rb).

### Phase 3: external agent exposure

- external lookup tools shipped as [`search_intents`](../../app/mcp/tools/search_intents.rb) and [`get_intent`](../../app/mcp/tools/get_intent.rb).
- those tools are registered in [`Tools::Registry`](../../app/mcp/tools/registry.rb) and covered by tool specs.

## What Is Still Missing

### Issue enhancement CIR detection and draft creation

The current [`EnhanceIssueActivity`](../../app/temporal/activities/enhance_issue_activity.rb) asks clarifying questions that surface constraints and rejected alternatives, but it does not:

- detect CIR-worthy issue language as a distinct step
- draft a linked `ChangeIntent`
- include a CIR draft proposal in the enhancement output
- persist an issue-linked draft for later approval

That means RDR-042's issue-detection part of Phase 3 is still missing, despite [#2697](https://github.com/viamin/paid/issues/2697) and [#2761](https://github.com/viamin/paid/issues/2761) being closed.

## Proposed Follow-Up Issue

No writable GitHub credential was available in this workspace, so the follow-up issue could not be filed directly from this run. The issue that should be filed is:

- Title: `RDR-042: restore CIR auto-detection and draft creation in EnhanceIssueActivity`

Suggested acceptance criteria:

- `EnhanceIssueActivity` explicitly evaluates whether an issue contains a non-obvious constraint or a rejected reasonable alternative worth preserving as a CIR.
- When the enhancement flow identifies such a case, it produces a draft CIR payload linked to the issue instead of only asking generic clarifying questions.
- The enhancement output makes the proposed CIR visible to the human reviewer with a clear approve/edit path.
- The resulting draft `ChangeIntent` is issue-linked, remains `draft` until approval, and enters the knowledge pipeline only after approval.
- request, activity, and service specs cover both CIR-worthy and non-CIR-worthy issue bodies.

## Conclusion

RDR-042 should now be treated as **partially implemented**:

- Phase 1 shipped.
- Phase 2 shipped.
- Phase 3's external-agent lookup tools shipped.
- Phase 3's issue-enhancement CIR detection is still missing and needs a focused follow-up issue.
