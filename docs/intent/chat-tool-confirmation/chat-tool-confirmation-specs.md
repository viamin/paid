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
