# EARS Specs: Chat PR Proposal

> Testable claims for chat-driven pull request proposals. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r CHAT-PR-PROPOSAL-001`).

## Proposal Flow

- [x] **CHAT-PR-PROPOSAL-001** — When an authorized user proposes a pull
  request for a cloned workspace repo whose branch exists and whose committed
  state is pushable, the system SHALL push the named branch with the resolved
  GitHub credential, open a pull request against the project's default branch,
  and return the PR number, URL, repo path, branch name, and resolved token
  identity.
  *Tests:* `spec/mcp/tools/propose_pull_request_spec.rb`,
  `spec/mcp/tools/repo_write_credential_resolver_spec.rb`.
  *Code:* `Tools::ProposePullRequest#perform`,
  `Tools::RepoWriteCredentialResolver#resolve`.

- [x] **CHAT-PR-PROPOSAL-002** — When the chatting user has a linked active
  GitHub token that covers the target repo, the system SHALL prefer that token
  over the project's stored credential for both git push and pull-request API
  creation, and SHALL record the chosen identity in the audit log.
  *Tests:* `spec/mcp/tools/repo_write_credential_resolver_spec.rb`,
  `spec/mcp/tools/propose_pull_request_spec.rb`.
  *Code:* `Tools::RepoWriteCredentialResolver#resolve`,
  `Tools::ProposePullRequest#record_audit_event!`.

- [x] **CHAT-PR-PROPOSAL-003** — When the working tree for the target repo has
  uncommitted changes and `confirm_commit_first` is not explicitly true, the
  system SHALL reject the proposal instead of silently opening a PR from stale
  committed state.
  *Tests:* `spec/mcp/tools/propose_pull_request_spec.rb`.
  *Code:* `Tools::ProposePullRequest#ensure_proposable_worktree!`.

- [x] **CHAT-PR-PROPOSAL-004** — When `depends_on` references are supplied, the
  system SHALL append `Depends on owner/repo#N` lines to the PR body exactly in
  Paid's existing dependency-parser syntax so cross-repo dependencies resolve
  without new parser logic.
  *Tests:* `spec/mcp/tools/propose_pull_request_spec.rb`.
  *Code:* `Tools::ProposePullRequest#render_pull_request_body`.

- [x] **CHAT-PR-PROPOSAL-005** — When more than one cloned repo in the session
  has uncommitted changes at proposal time, the system SHALL surface a warning
  in the proposal result so the user can review coordinated workspace state
  before shipping multiple PRs.
  *Tests:* `spec/mcp/tools/propose_pull_request_spec.rb`.
  *Code:* `Tools::ProposePullRequest#workspace_warnings`.

- [x] **CHAT-PR-PROPOSAL-006** — When a chat-triggered agent run opens a pull
  request without a backing issue, the system SHALL derive fallback PR metadata
  from the run's custom prompt, including an explicitly requested PR title when
  present, instead of using generic platform text.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`.
  *Code:* `Activities::CreatePullRequestActivity`.

- [x] **CHAT-PR-PROPOSAL-007** — When a successful agent run's stdout contains
  a streaming `error`/`turn.failed` JSONL event from a superseded fallback
  attempt, the agent summary SHALL reflect the winning attempt's output and
  SHALL NOT surface the stale error, so the PR description generator receives
  real agent output instead of blanking to the default body.
  *Test:* `spec/models/agent_run_spec.rb`.
  *Code:* `AgentRun#agent_summary`, `AgentRun#extract_text_from_stdout`.

- [x] **CHAT-PR-PROPOSAL-008** — When custom-prompt content is published as PR
  title/body fallback metadata, the system SHALL redact known provider secret
  shapes (GitHub tokens plus bare Anthropic/OpenAI/Google/Slack/Stripe keys and
  PEM blocks) and SHALL neutralize inline markdown link/image syntax so prompt
  content cannot render tracking images or phishing links in the PR body.
  *Test:* `spec/services/knowledge/redaction/scanner_spec.rb`,
  `spec/temporal/activities/create_pull_request_activity_spec.rb`.
  *Code:* `config/knowledge/redaction_patterns.yml`,
  `Activities::CreatePullRequestActivity#neutralize_inline_markdown`.
