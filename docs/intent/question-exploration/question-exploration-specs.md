# EARS Specs: Question Exploration

Status: `[ ]` planned; no implementation is claimed by these specs.

- [x] **QUESTION-EXPLORATION-001** — When a user opens an enabled Inbox clarifying question, Paid SHALL open that user's active conversation for the Inbox item, reusing it on subsequent or concurrent opens. A closed or archived conversation SHALL be replaced rather than reopened or used.
  *Tests:* `spec/services/inbox/open_interactive_chat_spec.rb`, `spec/policies/chat_message_policy_spec.rb`, `spec/services/chat_sessions/resolve_tool_call_spec.rb`.
  *Code:* `app/services/inbox/open_interactive_chat.rb`, `app/policies/chat_message_policy.rb`, `app/services/chat_sessions/resolve_tool_call.rb`.
- [ ] **QUESTION-EXPLORATION-002** — While a user explores a question in chat, Paid SHALL preserve partial answers and allow other questions to be answered without treating an exploration request as an answer or clearing unresolved questions.
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
- [x] **QUESTION-EXPLORATION-014** — The interactive Inbox chat SHALL persist its Inbox item key, creator, opened/closed timestamps and queue-metadata audit snapshot. Only a user with the project’s comment authority SHALL create or use it. Inbox context SHALL be available through an explicit section-query service and SHALL NOT be inserted into the system prompt by default.
  *Tests:* `spec/services/inbox/open_interactive_chat_spec.rb`, `spec/services/inbox/chat_context_spec.rb`, `spec/policies/chat_message_policy_spec.rb`.
  *Code:* `app/services/inbox/open_interactive_chat.rb`, `app/services/inbox/chat_context.rb`, `app/policies/chat_session_policy.rb`, `app/policies/chat_message_policy.rb`.
