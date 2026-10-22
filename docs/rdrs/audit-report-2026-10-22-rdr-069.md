# RDR-069 Closeout Audit — 2026-10-22

- **RDR**: [RDR-069: Question-Centered Chat Exploration](RDR-069-question-centered-chat-exploration.md)
- **Audit date**: 2026-10-22
- **Closeout issue**: [#4322](https://github.com/viamin/paid/issues/4322) (open — see Closure decision)
- **Umbrella**: [#4309](https://github.com/viamin/paid/issues/4309) (open; this closeout `Tracks` it and does not close it)
- **Conclusion**: **Partially Implemented.** Every `QUESTION-EXPLORATION-*` claim except bounded investigations ships with running test evidence. One required behavior — human diagram comments reaching the conversation and the assistant — was shipped only as a write path and was completed by this audit.

This audit follows the [RDR Closeout Checklist](closeout-checklist.md). It reads
the RDR's Problem Statement / Decision / Implementation and Validation sections
as the source of truth and the EARS trace in
[`question-exploration-specs.md`](../intent/question-exploration/question-exploration-specs.md)
as the status ledger, then verifies both against the current codebase and a
live test run. Closed-issue state is not treated as delivery evidence. The
merged code and specs of #4311, #4312, #4313 and #4316 were read and run
instead.

Eleven delivery children #4310–#4321 are closed on GitHub. #4317 (P08) is
currently open with `state_reason: reopened`; during its prior closed interval,
it did not ship any investigation surface, which this audit verified in code
(see `010` below). The other children's claimed behaviors were each confirmed
by reading their merged code and running their specs.

## Acceptance evidence

| EARS claim | Result | Code and test evidence |
| --- | --- | --- |
| `001` — reuse/resume the canonical linked conversation per Inbox question | Shipped | `app/services/clarifying_questions/open_chat.rb:39`, `app/services/chat_sessions/resolve_tool_call.rb`. Coverage: `spec/services/clarifying_questions/open_chat_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb`, `spec/services/inbox/open_interactive_chat_spec.rb`. |
| `002` — draft answers persist without posting; final answers post through the standard comment path | Shipped | `app/services/clarifying_questions/save_progress.rb`, `app/mcp/tools/save_clarifying_answer.rb`, `app/mcp/tools/submit_clarifying_answers.rb`, `app/services/clarifying_questions/submit_answers.rb`. Coverage: `spec/services/clarifying_questions/save_progress_spec.rb`, `spec/mcp/tools/save_clarifying_answer_spec.rb`, `spec/mcp/tools/submit_clarifying_answers_spec.rb`, `spec/integration/question_exploration_journey_spec.rb`. |
| `003` — diagram identifies its question, has a text equivalent, collapse/expand, keyboard interaction, comment input | Shipped | `app/views/chat_diagrams/_diagram.html.erb:6`, `app/javascript/controllers/diagram_controller.js:27`. Coverage: `spec/views/chat_diagrams/diagram_partial_spec.rb` (running), `spec/system/chat_diagrams_spec.rb` (browser-driven; skips without Chromium in this environment). |
| `004` — comments are attributed, retain question identity and textual context, and now reach the card, the assistant, and the JSON transport | Shipped (completed by this audit) | `app/models/chat_diagram_comment.rb`, `app/services/chat_diagrams/comment.rb:34`, `app/services/chat_diagrams/comment_serializer.rb`, `app/views/chat_diagrams/_diagram.html.erb:30`, `app/services/chat_sessions/build_system_prompt.rb:243`. Coverage: `spec/models/chat_diagram_comment_spec.rb`, `spec/services/chat_diagrams/comment_spec.rb`, `spec/views/chat_diagrams/diagram_partial_spec.rb`, `spec/requests/api/v1/chat_messages_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb`, `spec/integration/question_exploration_journey_spec.rb`. |
| `005` — a replaced diagram preserves human comments and releases visual source | Shipped | `app/services/chat_diagrams/replace.rb:26`. Coverage: `spec/services/chat_diagrams/replace_spec.rb`, `spec/integration/question_exploration_journey_spec.rb`. |
| `006` — a comment on an outdated element preserves context or asks for clarification | Shipped | `app/services/chat_diagrams/comment.rb:34`, `app/controllers/chat_diagram_comments_controller.rb:18`. Coverage: `spec/services/chat_diagrams/comment_spec.rb`, `spec/requests/chat_diagram_comments_spec.rb`. |
| `007` — project/tenant access and actor attribution on transcript, message, diagram, subscription and tool operations | Shipped | `app/policies/chat_session_policy.rb:104`, `app/policies/chat_message_policy.rb`, `app/channels/chat_channel.rb`, `app/controllers/chat_diagram_comments_controller.rb:14`. Coverage: `spec/policies/chat_session_policy_spec.rb`, `spec/policies/chat_message_policy_spec.rb`, `spec/channels/chat_channel_spec.rb`, `spec/requests/chat_diagram_comments_spec.rb`, `spec/integration/question_exploration_journey_spec.rb` (collaborator allowed, outsider denied). |
| `008` — investigate available facts first; ask how to investigate when the method is unclear | Shipped as prompt-level guidance; no runtime investigation | `app/services/chat_sessions/build_system_prompt.rb:231`. Coverage: `spec/services/chat_sessions/build_system_prompt_spec.rb`. The bounded-investigation runtime that would execute the advice is the `010` gap. |
| `009` — validate the typed description, escape untrusted content, never execute generated script | Shipped | `app/models/chat_diagram.rb:35`, `app/views/chat_diagrams/_diagram.html.erb`. Coverage: `spec/models/chat_diagram_spec.rb`, `spec/views/chat_diagrams/diagram_partial_spec.rb`. |
| `010` — budget and execution-policy enforcement, authorization before overage, progress and cancellation for long work | **Gap** | No investigation primitive, budget check, progress surface, or cancellation path exists in the repository: no investigation tool in `app/mcp/tools/`, no investigation table in `db/schema.rb` (`chat_diagrams`, `chat_diagram_comments`, `chat_messages`, `chat_session_projects`, `chat_sessions` are the only chat-side tables), and no `bounded_investigation`, `investigation_budget`, `investigation_progress`, or `investigation_cancel` identifier anywhere in `app/`, `lib/`, `config/`, or `spec/`. Two open issues claim this scope — [#4317](https://github.com/viamin/paid/issues/4317) (labelled `planning`, so auto-pick cannot reach it) and the focused [#4568](https://github.com/viamin/paid/issues/4568) — and neither has shipped any of it. |
| `011` — diagram interaction is exploration, not a preference or confidence increase | Shipped | `app/services/chat_sessions/build_system_prompt.rb:231`, `app/services/explicit_preferences/persist.rb`, `app/javascript/controllers/diagram_controller.js:4`. Coverage: `spec/services/chat_sessions/build_system_prompt_spec.rb`, `spec/services/explicit_preferences/`, `spec/system/chat_diagrams_spec.rb`. |
| `012` — authorized API/tool parity and consistent message context across HTML, Cable and SSE | Shipped for conversation, message and diagram actions; investigation slice missing | `app/controllers/api/v1/chat_diagram_comments_controller.rb`, `app/controllers/api/v1/chat_messages_controller.rb:215`, `app/services/chat_diagrams/serializer.rb`, `app/services/chat_diagrams/comment_serializer.rb`, `app/mcp/tools/present_chat_diagram.rb`, `app/models/chat_diagram.rb:82` (`diagram_created` Cable broadcast with rendered card HTML). Coverage: `spec/requests/api/v1/chat_diagram_comments_spec.rb`, `spec/requests/chat_diagram_comments_spec.rb`, `spec/requests/api/v1/chat_messages_spec.rb`, `spec/requests/api/v1/inbox_spec.rb`, `spec/channels/chat_channel_spec.rb`. There is no chat SSE transport in this application (the only SSE endpoint is the MCP client stream), so parity is HTML, ActionCable, and the mobile JSON API. The remaining investigation-action parity belongs to `010`/#4568. |
| `013` — archive preserves answers and evidence; reopen restores progress without discarded diagrams | Shipped (evidence restore completed by this audit) | `app/services/chat_sessions/archive.rb:56` (soft archive), `app/services/chat_sessions/build_system_prompt.rb:302`. Coverage: `spec/services/clarifying_questions/save_progress_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb`, `spec/integration/question_exploration_journey_spec.rb`. |
| `014`–`017`, `019` — Inbox chat audit metadata, frame rendering, choice-answer parsing, on-demand context, project-level rollout setting | Shipped | `app/services/inbox/open_interactive_chat.rb`, `app/services/inbox/chat_context.rb`, `app/services/clarifying_questions/choice_answers.rb`, `app/mcp/tools/update_project_settings.rb`, `app/views/projects/edit.html.erb`, `app/controllers/projects/clarifying_questions_controller.rb`. Coverage: `spec/services/inbox/`, `spec/services/clarifying_questions/choice_answers_spec.rb`, `spec/mcp/tools/update_project_settings_spec.rb`, `spec/requests/projects_spec.rb`. |
| `018` — one shared feature conversation, visible focus change without repointing, rollout-gated | Shipped | `app/services/clarifying_questions/open_chat.rb:76`, `app/models/chat_session.rb`. Coverage: `spec/services/clarifying_questions/open_chat_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb`, `spec/requests/api/v1/inbox_spec.rb`, `spec/integration/question_exploration_journey_spec.rb`. |

## Corrections made by this audit

The unit-level claims for `004` and `013` were marked implemented, but the
shipped code did not deliver the behavior the RDR describes, so this audit
fixed the divergence rather than reporting it as satisfied:

1. **Diagram comments were write-only.** `ChatDiagramComment` was created by
   the HTML and API endpoints but read by nothing: no view, no serializer, no
   prompt section. A collaborator's question about a diagram element never
   appeared in the transcript and never reached the assistant it was aimed at,
   which is the RDR's "selecting an element adds that element as discussion
   context". Fixed by rendering comments in the card, sharing one comment
   payload across the HTML and JSON transports, and adding a bounded diagram
   comment section to the exploration context.
2. **Saved evidence context was never restored.** `evidence_context` was
   persisted but never rendered anywhere, so reopening a conversation returned
   the draft answer without the human context that justified it. Fixed in the
   pending-question rendering.
3. **The diagram card had no non-browser coverage.** Keyboard selection,
   comment input and the "no script surface" boundary were asserted only by a
   Cuprite system spec that skips when Chromium is unavailable. Added
   `spec/views/chat_diagrams/diagram_partial_spec.rb`.
4. **No end-to-end journey evidence existed.** Added
   `spec/integration/question_exploration_journey_spec.rb`, which carries one
   person from the Inbox question through a shared conversation, a diagram and
   an element comment, method redirection, partial progress, archive and
   reconnect, and the final posted answer, and asserts the answer and its
   evidence afterwards.
5. **Reading diagram comments back introduced two query defects.** Rendering
   comments in the card and in the JSON payload made every transcript path load
   a diagram's comments lazily, so a page of messages issued one query per
   diagram; the prompt's comment section then loaded every diagram and every
   comment in the session in Ruby to keep only the newest 20. Fixed by
   eager-loading `chat_diagram: :comments` on the message scopes
   (`app/controllers/chat_messages_controller.rb:16`,
   `app/controllers/api/v1/chat_messages_controller.rb:19`,
   `app/controllers/chat_sessions_controller.rb:53,74,572`,
   `app/views/chat_sessions/_conversation.html.erb:78`) and bounding the prompt
   read in SQL (`app/services/chat_sessions/build_system_prompt.rb:257`).

## Verification run

```
RAILS_ENV=test bundle exec rspec \
  spec/services/chat_sessions spec/services/chat_diagrams \
  spec/services/clarifying_questions spec/services/inbox \
  spec/services/explicit_preferences spec/requests/chat_sessions_spec.rb \
  spec/requests/chat_messages_spec.rb spec/requests/chat_diagram_comments_spec.rb \
  spec/requests/api/v1 spec/requests/projects spec/requests/projects_spec.rb \
  spec/channels spec/policies spec/mcp spec/models/chat_session_spec.rb \
  spec/models/chat_diagram_spec.rb spec/models/chat_diagram_comment_spec.rb \
  spec/views spec/integration spec/system
```

Result: **3043 examples, 0 failures, 23 pending** (2026-10-22). All 23 pending
are `spec/system` examples skipped with "Chromium is not available for
Cuprite", which is an environment limit, not a product gap; the new view spec
provides running evidence for the same markup. The 23 are the pre-existing
`spec/system` examples in the listed directories — none is a `pending` marker on
a previously passing example, and `spec/system/chat_diagrams_spec.rb` declares
its skip explicitly rather than being marked pending.

`node bin/coherence-check.mjs --root /workspace` reports 1,283 specs (1,241
`[x]`, 25 `[ ]`), lists `QUESTION-EXPLORATION-010` as the only uncovered
question-exploration claim, and finds all arrow references valid. The five
pre-existing `CREATE-FEATURE-*`/`FEAT-NAME-001` reverse orphans are unrelated to
this RDR. `bundle exec rubocop` passes on every file this audit touched.

## Rollout guard disposition

**Satisfied and still enforced.** The project-level setting this RDR's Rollout
Guard requires shipped with #4311
(`projects.question_exploration_enabled`, disabled by default, writable only
through the authorized project settings form and the `update_project_settings`
tool). It gates the feature-conversation entry; disabling it preserves existing
conversations, answers, and evidence and changes no other policy. The
corrections in this audit extend existing chat rendering and prompt context
only — they add no new opt-in surface and do not make guarded behavior default.
The investigations still missing under #4568 must land behind the same setting.

## Remaining gaps

One unmet acceptance criterion remains. Two issues currently claim it, so
this audit records the verified state instead of asserting ownership:

| Gap | Claimed by | Verified state on 2026-10-22 |
| --- | --- | --- |
| `QUESTION-EXPLORATION-010` plus the investigation slice of `012`: budget and execution-policy enforcement, authorization before exceeding either, progress and cancellation for long-running work, and the API/tool parity those actions need | [#4317](https://github.com/viamin/paid/issues/4317) (P08, under epic #4309) | **Open**, carrying the `planning` label, so it stays out of the auto-pick queue while the gap is unimplemented. |
| same | [#4568](https://github.com/viamin/paid/issues/4568) (focused follow-up) | **Open**, labelled `enhancement` and `P1` only, so auto-pick can reach it. Filed on the premise that #4317 "is closed as completed"; that premise does not match #4317's current GitHub state, which is open. |

The repository evidence is the same under either owner: no investigation tool
in `app/mcp/tools/`, no investigation table in `db/schema.rb`, and no
`bounded_investigation` / `investigation_budget` / `investigation_progress` /
`investigation_cancel` identifier anywhere in `app/`, `lib/`, `config/`, or
`spec/`. #4317's `planning` label is why the focused, skip-label-free #4568
exists at all. Reconciling which of the two owns the implementation is left to
the umbrella's P01 (#4310), which the epic already assigns reconciliation of
remaining overlaps; the closeout's requirement holds either way — the gap has a
focused owner and must ship before #4322 can close. No other
`QUESTION-EXPLORATION-*` gap remains: `012`'s conversation, message, and
diagram-action parity ships, and its investigation slice is the same work.

## Closure decision

Do **not** close #4322. `QUESTION-EXPLORATION-010` and the investigation slice
of `QUESTION-EXPLORATION-012` are unimplemented, so the closeout's own
acceptance is not met. #4322 records an explicit dependency on the gap issue
and keeps `Tracks #4309` language; per the closeout checklist, only the
umbrella's own final acceptance audit may close #4309, and only after
bounded investigations ship with code and passing tests.
