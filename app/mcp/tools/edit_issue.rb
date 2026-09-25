# frozen_string_literal: true

module Tools
  class EditIssue < BaseTool
    include GithubIssueToolSupport

    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "edit_issue"
    def self.write_operation? = true

    def self.description
      "Update an existing GitHub issue. Pass only the fields you want to change. " \
        "For new work related to a closed issue, use create_issue to file a follow-up instead of reopening it. " \
        "For body edits, the caller should read the current issue body first " \
        "(via get_issue_details), apply the desired changes, and pass the complete " \
        "new body — this is a full replacement, not a patch."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_number: { type: "integer", description: "The GitHub issue number" },
          title: { type: "string", description: "New title (omit to keep current)" },
          body: { type: "string", description: "New body in full — read first, modify, then pass the complete replacement" },
          state: { type: "string", description: "New state; reopening a closed issue requires review confirmation and a reason", enum: %w[open closed] },
          reopen_review_confirmed: {
            type: "boolean",
            description: "Must be true, in addition to confirmed, after reviewing the original closure before reopening a closed issue"
          },
          reopen_reason: {
            type: "string",
            description: "Why reopening is necessary; required when reopening a closed issue"
          },
          labels: {
            type: "array",
            items: { type: "string" },
            description: "New labels (replaces all existing labels)"
          },
          assignees: {
            type: "array",
            items: { type: "string" },
            description: "New assignees (replaces all existing)"
          },
          confirmed: {
            type: "boolean",
            description: "Must be true to execute this write operation"
          }
        },
        required: %w[project_id issue_number confirmed]
      }
    end

    # @spec CHAT-TOOL-CONFIRMATION-001, GITHUB-SYNC-013, ISSUE-REOPEN-REVIEW-004
    def perform(project_id:, issue_number:, confirmed: false, reopen_review_confirmed: false, reopen_reason: nil, title: nil, body: nil, state: nil, labels: nil, assignees: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to edit an issue" unless confirmed

      project = project_for(project_id)
      reopening_issue = validate_state_transition!(project, issue_number, state, reopen_review_confirmed, reopen_reason)
      client = require_github_client!(project)
      require_trusted_human_credential!(project, client)
      repo = project.full_name

      options = {}
      options[:title] = title if title
      options[:body] = body if body
      options[:state] = state if state
      options[:labels] = labels if labels
      options[:assignees] = assignees if assignees

      raise ArgumentError, "No fields to update" if options.empty?

      if labels
        validate_labels!(client, repo, labels)
      end

      issue = client.update_issue(repo, issue_number, **options)
      local_issue = sync_local_issue!(project, issue, parse_dependencies: options.key?(:body))
      record_reopen!(local_issue, reason: reopen_reason) if reopening_issue
      record_audit_event(project, issue_number:, repo:, changes: options.keys, reopened: reopening_issue.present?, reopen_reason:)

      {
        number: issue.number,
        url: issue.html_url,
        title: issue.title,
        state: issue.state
      }
    end

    private

    # @spec ISSUE-REOPEN-REVIEW-002 @spec ISSUE-REOPEN-REVIEW-003
    def validate_state_transition!(project, issue_number, state, reopen_review_confirmed, reopen_reason)
      issue = project.issues.find_by(github_number: issue_number)
      return unless issue && state

      if reopening?(issue, state) && !reopen_review_confirmed
        raise ArgumentError, "Reopen review confirmation required: set reopen_review_confirmed=true after validating the original closure"
      end

      raise ArgumentError, "Reopen reason required" if reopening?(issue, state) && reopen_reason.blank?
      return issue if reopening?(issue, state)

      return unless state == "closed" && issue.reopen_review_pending?

      raise ArgumentError, "Cannot close this issue while its reopen review is pending"
    end

    def reopening?(issue, state)
      state == "open" && issue.github_state == "closed"
    end

    def record_reopen!(issue, reason:)
      issue.update!(reopened_at: Time.current, reopened_by: user, reopen_reason: reason)
    end

    def record_audit_event(project, issue_number:, repo:, changes:, reopened:, reopen_reason:)
      action = reopened ? "issue.reopened" : "issue.updated"
      metadata = { issue_number:, repo:, changes: }
      metadata[:reason] = reopen_reason if reopened
      Audit::RecordEvent.call(action:, actor: user, subject: project, metadata:)
    end

    def require_trusted_human_credential!(project, client)
      return if project.trusted_github_user?(client.authenticated_login)

      raise ArgumentError, "Issue edits require a trusted human GitHub credential"
    end

    def sync_local_issue!(project, github_issue, parse_dependencies: false)
      issue = Issues::UpsertFromGithub.call(project:, github_issue:)
      Issues::ParseDependencies.call(issue:) if parse_dependencies
      issue
    end
  end
end
