# EARS Specs: Question Exploration

Status: `[ ]` planned; no implementation is claimed by these specs.

- [ ] **QUESTION-EXPLORATION-001** — When a user opens an enabled Inbox clarifying question, Paid SHALL open its feature conversation, or standalone-issue conversation, focused on that question, reusing the same conversation on subsequent or concurrent opens.
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
