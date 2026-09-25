# EARS Specs: Question Exploration

Status: the chat-entry and final-answer submission claims below are implemented;
diagram and durable-progress work remains planned.

- [x] **QUESTION-EXPLORATION-001** — When a user with issue-comment permission opens an Inbox clarifying-question item, Paid SHALL open one canonical linked chat, reusing an active chat and restoring an archived one. The chat SHALL be created under that user with the generic title "Clarifying questions", carry the linked issue/PR and pending-question context, and allow follow-up questions.
  *Tests:* `spec/services/clarifying_questions/open_chat_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb`.
  *Code:* `app/services/clarifying_questions/open_chat.rb`, `app/controllers/projects/clarifying_questions_controller.rb`, `app/services/chat_sessions/build_system_prompt.rb`.

- [x] **QUESTION-EXPLORATION-002** — When the user confirms final ordered answers in a linked exploration chat, Paid SHALL post them through the standard clarifying-answer comment path, adjust labels, and remove the inbox item only after the comment succeeds. Users without issue-comment permission SHALL not be offered or able to invoke this action.
  *Tests:* `spec/mcp/tools/submit_clarifying_answers_spec.rb`, `spec/requests/projects/clarifying_questions_spec.rb`.
  *Code:* `app/mcp/tools/submit_clarifying_answers.rb`, `app/services/clarifying_questions/submit_answers.rb`.
- [ ] **QUESTION-EXPLORATION-003** — When Paid presents a diagram in chat, it SHALL identify the question, provide a text equivalent, allow expansion/collapse and keyboard interaction, and include a text input for comments on that diagram.
- [ ] **QUESTION-EXPLORATION-004** — When a user comments on a diagram or selected element, Paid SHALL attribute the comment to the user and retain question identity and sufficient textual context for the comment to remain understandable after the diagram is removed.
- [ ] **QUESTION-EXPLORATION-005** — When a diagram is replaced or discarded, Paid SHALL preserve human comments, answers and evidence summaries without requiring retention of non-final diagram source or visual revision history.
- [ ] **QUESTION-EXPLORATION-006** — When Paid receives a comment against an outdated diagram element, it SHALL preserve the identified context or request clarification and SHALL NOT silently associate the comment with a different element.
- [ ] **QUESTION-EXPLORATION-007** — While an authorized collaborator uses a shared exploration conversation, Paid SHALL enforce project and tenant access on transcript, message, diagram, subscription and tool operations and SHALL attribute actions to that collaborator rather than the session creator.
- [ ] **QUESTION-EXPLORATION-008** — When selecting a question's exploration method, Paid SHALL investigate available facts first, adapt its aid to context, and ask how the person wants to investigate when the method is unclear.
- [ ] **QUESTION-EXPLORATION-009** — When Paid renders a generated diagram, it SHALL validate its typed description, escape untrusted content and prevent generated scripts from executing in the application origin; invalid output SHALL leave a usable textual conversation.
- [ ] **QUESTION-EXPLORATION-010** — When Paid initiates an investigation, it SHALL enforce the configured budget and execution policy, request authorization before exceeding either, and expose progress and cancellation for long-running work.
- [ ] **QUESTION-EXPLORATION-011** — When a user selects, collapses or experimentally edits a diagram, Paid SHALL treat the interaction as exploration and SHALL NOT infer a preference or increase intent certainty solely from that interaction.
- [ ] **QUESTION-EXPLORATION-012** — When an exploration action is available through the UI, Paid SHALL expose an equivalent authorized API/tool action and consistent message context through HTML, Cable and SSE transports.
- [ ] **QUESTION-EXPLORATION-013** — When a conversation is archived or an investigation is interrupted, Paid SHALL preserve the related human answers and evidence; reopening SHALL restore current question progress without requiring discarded diagrams.
