# RDR-069 Audit Report — 2026-10-12 Umbrella Acceptance

- **RDR**: [RDR-069: Question-Centered Chat Exploration](RDR-069-question-centered-chat-exploration.md)
- **Audit date**: 2026-10-12
- **Umbrella issue**: [#4309](https://github.com/viamin/paid/issues/4309) (epic — open)
- **Closeout children**: P01–P12, C69, C70, C71
- **Conclusion**: **Partially Implemented.** The exploration foundation
  (per-creator session selection, the linked clarifying-question chat, the
  project-scoped shared conversation, the Inbox chat context service, the
  embedded chat panel inside the Inbox detail frame, and chat-composed
  choice answers) ships with code and test evidence. The diagram card and
  comment lifecycle, durable per-question progress, adaptive clarification,
  bounded investigation dispatch, and the temporary-visual lifecycle
  constraints in the RDR are unimplemented. The umbrella remains open for
  the closeout children that file those gaps.

Follows the [RDR Closeout Checklist](closeout-checklist.md). This audit
checks shipped behavior and test evidence, not issue closure alone.

## Acceptance evidence

| RDR-069 criterion | Result | Code and test evidence |
| --- | --- | --- |
| Per-creator session selection for a clarifying-question Inbox item | Shipped | `app/services/inbox/open_interactive_chat.rb` (`active_chat`, `resume_closed_chat`, `create_chat`) under `user.with_lock`; `Inbox::OpenInteractiveChatCallConcurrency` covers simultaneous opens converging on the same chat. `app/services/clarifying_questions/open_chat.rb` covers the legacy clarifying-question path. Coverage: `spec/services/inbox/open_interactive_chat_spec.rb`, `spec/services/inbox/open_interactive_chat_call_concurrency_spec.rb`, `spec/services/clarifying_questions/open_chat_spec.rb`. |
| Linked chat for the legacy clarifying-question entry | Shipped | `ClarifyingQuestions::OpenChat` (canonical linked chat, partial unique index on `clarifying_question_issue_id`, restored on archive) and `app/controllers/projects/clarifying_questions_controller.rb` (`open_chat`). Coverage: `spec/services/clarifying_questions/open_chat_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb`. |
| Project/tenant access on shared exploration transcript, message, subscription, and tool operations | Shipped | `ProjectPolicy#explore?` (`app/policies/project_policy.rb:41`) requires account owner/admin or project viewer; `ChatMessagePolicy` re-checks on send. `ChatSession#sidebar_broadcast_stream` keys Turbo Streams on `[ project, :chat_sessions ]` for clarifying-question chats and `[ account, :chat_sessions ]` otherwise (`app/models/chat_session.rb:391`). Coverage: `spec/policies/project_policy_spec.rb`, `spec/policies/chat_message_policy_spec.rb`, `spec/policies/chat_session_policy_spec.rb`, `spec/channels/chat_channel_spec.rb`, `spec/jobs/chat_sessions/process_message_job_spec.rb`, `spec/jobs/chat_sessions/resolve_tool_call_job_spec.rb`, `spec/services/chat_sessions/resolve_tool_call_spec.rb`. |
| Inbox chat persistence and explicit context service | Shipped | `ChatSession` columns `inbox_item_key`, `inbox_item_metadata`, `opened_at`, `closed_at` (`db/schema.rb`); `Inbox::OpenInteractiveChat` writes the audit snapshot and an Inbox-keyed chat title. `Inbox::ChatContext` resolves record-backed entries on demand without inserting context into the system prompt (`app/services/inbox/chat_context.rb`); `Mcp::Tools::GetInboxChatContext` exposes the same boundary. Coverage: `spec/services/inbox/open_interactive_chat_spec.rb`, `spec/services/inbox/chat_context_spec.rb`, `spec/mcp/tools/get_inbox_chat_context_spec.rb`. |
| Linked chat panel inside the Inbox detail frame | Shipped | `app/controllers/projects/clarifying_questions_controller.rb` (chat panel partial), `app/views/chat_sessions/_frame.html.erb`, `app/views/chat_sessions/_chat_panel.html.erb`, `app/views/chat_sessions/_session_details.html.erb`. The full `/chat` route continues to render the normal shell; popup requests render the popup variant; embedded destinations carry `data-turbo-frame="_top"`. Coverage: `spec/requests/projects/clarifying_questions_spec.rb`, `spec/requests/chat_sessions_spec.rb`. |
| Chat-composed choice answers (assistant-spelled, not widget-composed) | Shipped | `ClarifyingQuestions::ChoiceAnswers` (`app/services/clarifying_questions/choice_answers.rb`) accepts canonical `Label (text)`, rendered `Label) text`, bare label, 1-based number, or letter; `BuildSystemPrompt` renders the canonical option lines and the accepted answer forms; the offered-option invariant of `OPERATOR-INBOX-012` is preserved. Coverage: `spec/services/clarifying_questions/choice_answers_spec.rb`, `spec/mcp/tools/submit_clarifying_answers_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb`. |
| Final ordered answers posted through the standard clarifying-answer path | Shipped | `app/mcp/tools/submit_clarifying_answers.rb` invokes `ClarifyingQuestions::SubmitAnswers`, which posts the GitHub comment, adjusts labels, and clears the inbox item only after GitHub accepts the comment. Coverage: `spec/mcp/tools/submit_clarifying_answers_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb`. |
| Diagram card lifecycle (text equivalent, expansion/collapse, keyboard, comment input) | **Gap** | No diagram message type, renderer, comment composer, or selection/collapse state is implemented. The chat renderer, message serializer, and Stimulus components carry no diagram code; `app/javascript/lib/safe_markdown.js` boundary has no diagram-extension code. |
| Diagram comment attribution and stale-element handling | **Gap** | No diagram-comment record type, no element-selection identifier, and no stale-element handling exist. |
| Diagram replacement preserves human comments and answer evidence without retaining non-final visual source | **Gap** | No diagram lifecycle; no replacement or discard path exists. |
| Adaptive exploration-method selection and clarification prompts | **Gap** | No method-selection logic; clarifying-question prompts and chat answers use the existing clarifying-question widget semantics, not the adaptive A/B/both/neither/conditional/free-text set. |
| Bounded investigation dispatch with budget, progress, and cancellation | **Gap** | No investigation dispatch service or budget enforcement; `ChatSessions::ToolDispatch` has no investigation-only tool. |
| Diagram-rendering safety (validation, script-execution prevention, text-only fallback) | **Gap** | No diagram renderer exists. |
| Diagram interaction not treated as preference or certainty | **Gap** | No diagram interactions exist to evaluate. |
| Archive/investigation interruption preserves human answers and evidence | **Gap** | No investigation lifecycle; no diagram-evidence summarization path. |
| Per-question durable progress across sessions and reconnects | **Gap** | Per-question state is the existing `Inbox::Queue` entry plus the linked chat. No per-question answer/facet/notes record; partial-answer resumption is not implemented beyond reopening the chat. |
| UI/API/tool parity for every exploration action | **Gap** | The clarifying-question final-answer path has API/tool parity (`SubmitClarifyingAnswers` MCP tool). The unimplemented exploration actions have no UI, no API, and no tool surfaces. |

## EARS reconciliation

`docs/intent/question-exploration/question-exploration-specs.md` lists 17
claims. Seven are marked `[x]` and are reconciled by this audit
(`QUESTION-EXPLORATION-001`, `-002`, `-007`, `-014`, `-015`, `-016`, `-017`)
with code and test evidence above. Ten claims remain pending and are
unimplemented: `-003`, `-004`, `-005`, `-006`, `-008`, `-009`, `-010`,
`-011`, `-012`, `-013`. They map to the gaps above and to children P03, P04,
P07, and P08 of the umbrella. `bin/coherence-check.mjs` reports valid arrow
references and full `@spec` coverage for the implemented claims.

## Stale status reconciled by this audit

- `docs/rdrs/RDR-069-question-centered-chat-exploration.md`: status moves
  from `Accepted` to `Partially Implemented`.
- `docs/rdrs/README.md`: RDR-069 row status moves from `Accepted` to
  `Partially Implemented`.
- `docs/arrows/index.yaml`: the `question-exploration` segment status moves
  from `MAPPED` to `PARTIAL`, audited 2026-10-12.

## Rollout guard preserved

RDR-069's rollout guard requires a project-level setting that is initially
disabled for existing projects and preserves existing Inbox actions. No such
configuration gate exists in the working tree. The shipped chat-session
selection, linked-chat panel, and chat-composed answer validator are additive
over existing surfaces and do not enroll any existing project into a new
mode. The audit does not introduce or flip a flag; the existing exploration
path is reachable through the existing Inbox entry surfaces without any
project operator action. Disable/enable semantics are therefore not yet
defined; the rollout guard is treated as a gap filed against C69.

## Remaining work and deployment prerequisites

No remaining code work exists in the shipped scope. The RDR's remaining
acceptance criteria are unimplemented and are tracked by the umbrella
children P03 (diagrams + comments), P04 (durable progress + answer
evidence), P07 (adaptive clarification + explicit preferences), and P08
(bounded investigations). Those children must complete and validate before
RDR-069 can move to **Implemented**. The umbrella issue #4309 must remain
open; the closeout issue for this audit uses non-closing language so the
umbrella's own final acceptance audit decides closure on shipped evidence.

## Verification record

The audit environment ran `bundle install`, `bin/rails db:prepare`
(PostgreSQL via `DATABASE_URL`), and `bin/coherence-check.mjs`. The
affected suite — `spec/services/inbox/open_interactive_chat_spec.rb`,
`spec/services/inbox/open_interactive_chat_call_concurrency_spec.rb`,
`spec/services/inbox/chat_context_spec.rb`,
`spec/services/clarifying_questions/open_chat_spec.rb`,
`spec/services/clarifying_questions/choice_answers_spec.rb`,
`spec/mcp/tools/submit_clarifying_answers_spec.rb`,
`spec/mcp/tools/get_inbox_chat_context_spec.rb`,
`spec/services/chat_sessions/resolve_tool_call_spec.rb`,
`spec/services/chat_sessions/build_system_prompt_spec.rb`,
`spec/policies/chat_message_policy_spec.rb`,
`spec/policies/project_policy_spec.rb`,
`spec/policies/chat_session_policy_spec.rb`,
`spec/channels/chat_channel_spec.rb`,
`spec/jobs/chat_sessions/process_message_job_spec.rb`,
`spec/jobs/chat_sessions/resolve_tool_call_job_spec.rb`,
`spec/requests/chat_sessions_spec.rb`,
`spec/requests/projects/clarifying_questions_spec.rb` — ran without
regressions in this audit (other changes were unrelated and were not in
scope).
