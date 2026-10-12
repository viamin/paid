# RDR-069 Closeout Audit — 2026-10-12

- **RDR**: [RDR-069: Question-Centered Chat Exploration](RDR-069-question-centered-chat-exploration.md)
- **Closeout issue**: [#4322](https://github.com/viamin/paid/issues/4322) (open — kept open, see Closure decision)
- **Umbrella**: [#4309](https://github.com/viamin/paid/issues/4309) (open; this closeout `Tracks` it and does not close it)
- **Conclusion**: **Partially Implemented.** The chat-entry/reuse, final-answer
  submission, access control, and Inbox-chat context foundation that RDR-069
  extends are shipped with passing test evidence. The diagram-card,
  durable-progress, adaptive-clarification, and bounded-investigation
  behaviors that make the experience "question-centered" are not shipped; they
  remain open, planning-stage issues (#4312, #4313, #4316, #4317) that this
  closeout already depended on, plus one additional gap identified below
  (#4311) that this audit adds as an explicit dependency.

This audit reads the RDR's Problem Statement/Decision/Validation sections as
the source of truth and the EARS trace in
`docs/intent/question-exploration/question-exploration-specs.md` as the
up-to-date status ledger, then verifies both against the current codebase and
a live test run — not against closed-issue history. Issues #3860, #3862, #3863, #3865, #3870, and #3871 (cited in the issue's existing-work reconciliation
section) predate this epic and ship unrelated `FeatureIntent`/approval-gate
contracts; they are not evidence for RDR-069's chat/diagram claims.

## Acceptance evidence

| EARS claim | Result | Code and test evidence |
| --- | --- | --- |
| `QUESTION-EXPLORATION-001` — reuse/resume the right conversation per Inbox question, legacy-entry canonical linked chat, title format | Shipped | `app/services/clarifying_questions/open_chat.rb`, `app/services/inbox/open_interactive_chat.rb`, `app/services/chat_sessions/resolve_tool_call.rb`, `app/services/chat_sessions/build_system_prompt.rb`, `app/views/chat_sessions/_conversation.html.erb`. Coverage: `spec/services/inbox/open_interactive_chat_spec.rb`, `spec/services/clarifying_questions/open_chat_spec.rb`, `spec/policies/chat_message_policy_spec.rb`, `spec/services/chat_sessions/resolve_tool_call_spec.rb`, `spec/requests/chat_sessions_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb` — all pass (see Verification run below). |
| `QUESTION-EXPLORATION-002` — final answers post through the standard comment path; permission-gated | Shipped | `app/mcp/tools/submit_clarifying_answers.rb`, `app/services/clarifying_questions/submit_answers.rb`. Coverage: `spec/mcp/tools/submit_clarifying_answers_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb` — pass. |
| `QUESTION-EXPLORATION-003`–`006`, `009`, `011` — diagram cards (question identity, collapse/expand, keyboard, comment input, attribution, stale-element handling, script-execution prevention, no preference inference from interaction) | **Gap** | No diagram rendering, card, or comment-input code exists anywhere under `app/models`, `app/services`, `app/controllers`, `app/views`, or `app/javascript` (confirmed by repo-wide search — zero matches for "diagram"). Tracked by open issue [#4312](https://github.com/viamin/paid/issues/4312) (P03), already an explicit dependency of #4322. |
| `QUESTION-EXPLORATION-007` — project/tenant access enforcement and actor attribution in shared exploration chat | Shipped | `app/models/chat_session.rb`, `app/policies/project_policy.rb`, `app/policies/chat_session_policy.rb`, `app/policies/chat_message_policy.rb`, `app/channels/chat_channel.rb`, `app/jobs/chat_sessions/process_message_job.rb`, `app/jobs/chat_sessions/resolve_tool_call_job.rb`, `app/services/chat_sessions/tool_dispatch.rb`. Coverage: `spec/models/chat_session_spec.rb`, `spec/policies/chat_session_policy_spec.rb`, `spec/requests/chat_sessions_spec.rb`, `spec/requests/chat_messages_spec.rb`, `spec/channels/chat_channel_spec.rb`, `spec/jobs/chat_sessions/process_message_job_spec.rb`, `spec/jobs/chat_sessions/resolve_tool_call_job_spec.rb` — pass. |
| `QUESTION-EXPLORATION-008` — investigate available facts first; ask how to investigate when unclear | **Gap** | No code selects or proposes an exploration method, or distinguishes investigation-first from asking. Tracked by open issues [#4316](https://github.com/viamin/paid/issues/4316) (P07) and [#4317](https://github.com/viamin/paid/issues/4317) (P08), both already explicit dependencies of #4322. |
| `QUESTION-EXPLORATION-010` — budget/execution-policy enforcement, authorization on overage, progress/cancellation for investigations | **Gap** | No "bounded investigation" primitive exists (confirmed by repo-wide search for `investigation_budget`, `bounded_investigation`, `ExplorationInvestigation` — zero matches beyond unrelated hits in `knowledge_run.rb`/`project.rb`/`feature_flags.rb`/`issues/closeout_status.rb`/`quality_recovery/suggest_fixes.rb`). Tracked by open issue #4317, already an explicit dependency of #4322. |
| `QUESTION-EXPLORATION-012` — every exploration UI action has an equivalent authorized API/tool action with matching HTML/Cable/SSE context | **Gap (partially tracked)** | The diagram- and investigation-specific slices of this claim are owned by #4312 and #4317 respectively (both already dependencies of #4322). The remaining slice — API/tool parity for the conversation-open/focus action itself, plus the RDR's project-level exploration rollout setting ("the first chat wiring issue owns this setting") — is explicitly owned by open issue [#4311](https://github.com/viamin/paid/issues/4311) (P02), which was **not** previously listed as a dependency of #4322. No rollout-setting code exists in the repo today (confirmed by repo-wide search for `question_exploration`, `exploration_enabled`, `chat_exploration` — zero matches). This audit adds #4311 as an explicit dependency of #4322 (see Closure decision). |
| `QUESTION-EXPLORATION-013` — archive/interrupt preserves answers/evidence; reopen restores progress without discarded diagrams | **Gap** | No durable per-question progress/evidence model exists beyond the chat transcript itself. Tracked by open issues #4313 (P04) and #4317 (P08), already explicit dependencies of #4322. |
| `QUESTION-EXPLORATION-014` — Inbox chat persists item key, creator, timestamps, queue-metadata audit snapshot; comment-authority gated; context via explicit query service, not injected into system prompt by default | Shipped | `app/services/inbox/open_interactive_chat.rb`, `app/services/inbox/chat_context.rb`, `app/policies/chat_session_policy.rb`, `app/policies/chat_message_policy.rb`. Coverage: `spec/services/inbox/open_interactive_chat_spec.rb`, `spec/services/inbox/chat_context_spec.rb`, `spec/policies/chat_message_policy_spec.rb` — pass. |
| `QUESTION-EXPLORATION-015` — legacy clarifying-question chat renders correctly inside a requested Turbo Frame; full-page links/controls opt out to `_top` | Shipped | `app/controllers/projects/clarifying_questions_controller.rb`, `app/controllers/chat_sessions_controller.rb`, `app/views/chat_sessions/_frame.html.erb`, `_chat_panel.html.erb`, `_session_details.html.erb`. Coverage: `spec/requests/projects/clarifying_questions_spec.rb`, `spec/requests/chat_sessions_spec.rb` — pass. |
| `QUESTION-EXPLORATION-016` — choice-question answer validator accepts every unambiguous selection spelling | Shipped | `app/services/clarifying_questions/choice_answers.rb`, `app/services/chat_sessions/build_system_prompt.rb`. Coverage: `spec/services/clarifying_questions/choice_answers_spec.rb`, `spec/mcp/tools/submit_clarifying_answers_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb` — pass. |
| `QUESTION-EXPLORATION-017` — Inbox chat context resolves record-backed items on demand without trusting record metadata as evidence | Shipped | `app/services/inbox/chat_context.rb`, `app/mcp/tools/get_inbox_chat_context.rb`. Coverage: `spec/services/inbox/chat_context_spec.rb`, `spec/mcp/tools/get_inbox_chat_context_spec.rb` — pass. |

## Verification run

```
RAILS_ENV=test bundle exec rspec \
  spec/services/inbox/open_interactive_chat_spec.rb \
  spec/services/clarifying_questions/open_chat_spec.rb \
  spec/policies/chat_message_policy_spec.rb \
  spec/services/chat_sessions/resolve_tool_call_spec.rb \
  spec/requests/chat_sessions_spec.rb \
  spec/requests/projects/clarifying_questions_spec.rb \
  spec/mcp/tools/submit_clarifying_answers_spec.rb \
  spec/models/chat_session_spec.rb \
  spec/policies/chat_session_policy_spec.rb \
  spec/requests/chat_messages_spec.rb \
  spec/channels/chat_channel_spec.rb \
  spec/jobs/chat_sessions/process_message_job_spec.rb \
  spec/jobs/chat_sessions/resolve_tool_call_job_spec.rb \
  spec/services/inbox/chat_context_spec.rb \
  spec/services/clarifying_questions/choice_answers_spec.rb \
  spec/services/chat_sessions/build_system_prompt_spec.rb \
  spec/mcp/tools/get_inbox_chat_context_spec.rb
```

Result: **467 examples, 0 failures** (2026-10-12).

## Rollout guard disposition

RDR-069's Rollout Guard calls for a project-level exploration rollout setting,
initially disabled for existing projects, owned by "the first chat wiring
issue." That setting does not exist in the codebase today. The behavior that
*is* shipped (001, 002, 007, 014–017) is an extension of the pre-existing,
already-enabled legacy clarifying-question chat entry point (RDR-028-era
`ClarifyingQuestions::OpenChat`), not a new opt-in surface — it introduces no
diagram, investigation, or preference behavior that the guard is meant to
gate. **Disposition: the guard is still required and remains pending**,
scoped to #4311 (which explicitly owns it). No shipped behavior bypasses or
needs to bypass the guard; nothing here should be read as license to expose
diagrams/investigations/preferences without it.

## Closure decision and prerequisites

Do **not** close #4322. Required gaps remain: diagram cards (#4312),
durable per-question progress/evidence (#4313), adaptive clarification and
explicit-preference handling (#4316), bounded investigations (#4317), and —
newly identified by this audit — conversation-open/focus API parity and the
rollout-guard setting (#4311). This audit adds #4311 to #4322's explicit
dependency list via the GitHub API so the closeout's own acceptance tracks
every unmet criterion, per the RDR closeout checklist. No new child issue was
filed because every gap found already has a focused, correctly-scoped open
issue under epic #4309.

Per the closeout checklist, #4322 keeps `Tracks #4309` language; only the
umbrella's own final acceptance audit (#4324 / the epic's final audit) may
close #4309.
