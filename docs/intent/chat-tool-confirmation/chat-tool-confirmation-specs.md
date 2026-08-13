# Chat Tool Confirmation Specs

> Testable claims for interactive chat write-tool confirmation. Status markers:
> `[x]` implemented, `[ ]` gap, `[D]` deferred.

- [x] **CHAT-TOOL-CONFIRMATION-001** - A pre-dispatch GitHub issue write tool
  exposed to chat SHALL require `confirmed: true` at execution time before
  performing side effects, including GitHub issue creation, issue edits, and
  label replacement.

  *Tests:* `spec/mcp/tools/create_issue_spec.rb`,
  `spec/mcp/tools/edit_issue_spec.rb`, `spec/mcp/tools/set_labels_spec.rb`.
  *Code:* `app/mcp/tools/create_issue.rb#perform`,
  `app/mcp/tools/edit_issue.rb#perform`, `app/mcp/tools/set_labels.rb#perform`.

- [x] **CHAT-TOOL-CONFIRMATION-002** - When the per-session auto-approve toggle
  is enabled, the system SHALL auto-dispatch eligible reversible write tools by
  injecting `confirmed: true` without showing a confirmation prompt, covering
  agent-run creation and GitHub issue creation, edits, and label changes, while
  higher-blast-radius mutations (settings, memberships, API keys, and Change
  Intent Records) SHALL keep requiring manual approval. Eligibility is declared
  per tool, not hardcoded by name, so new reversible write tools opt in where the
  toggle should apply.

  *Tests:* `spec/services/chat_sessions/agent_loop_spec.rb`
  ("auto-approves reversible GitHub issue writes like filing a new issue",
  "still requires a manual confirmation for write tools outside the auto-approve
  allowlist"), `spec/mcp/tools/registry_spec.rb` (`.auto_approve_eligible?`).
  *Code:* `ChatSessions::AgentLoop#auto_approve_eligible?`,
  `Tools::Registry.auto_approve_eligible?`,
  `Tools::BaseTool.auto_approve_eligible?`,
  `Tools::GithubIssueToolSupport` (ClassMethods),
  `Tools::TriggerAgentRun.auto_approve_eligible?`.

- [x] **CHAT-TOOL-CONFIRMATION-003** - When a chat-dispatched tool call is
  missing a required argument used for preflight authorization, the system SHALL
  return an `invalid_arguments` tool result that names the missing argument
  instead of surfacing an `internal_error`, including auto-approved write-tool
  calls.

  *Tests:* `spec/mcp/tools/base_tool_spec.rb`,
  `spec/mcp/tools/trigger_agent_run_spec.rb`,
  `spec/services/chat_sessions/agent_loop_spec.rb`.
  *Code:* `Tools::BaseTool#authorization_record_for`,
  `ChatSessions::ToolDispatch#normalize_tool_dispatch_result`.
