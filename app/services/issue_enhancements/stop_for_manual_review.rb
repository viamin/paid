# frozen_string_literal: true

module IssueEnhancements
  class StopForManualReview
    COMMENT_MARKER = "<!-- paid:enhance-issue-manual-review -->"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, reason:)
      @project = project
      @issue = issue
      @reason = reason
    end

    # @spec ISSUE-ENHANCEMENT-002, ISSUE-ENHANCEMENT-011
    def call
      should_post = issue.with_lock do
        newly_stopped = issue.paid_state != "manual_review"
        issue.update!(paid_state: "manual_review", needs_input_questions: nil)
        newly_stopped
      end
      remove_needs_input_label
      post_comment if should_post && !comment_present?
    end

    private

    attr_reader :project, :issue, :reason

    def remove_needs_input_label
      label = project.enhance_issue_needs_input_label_name
      return unless issue.has_label?(label)

      project.client.remove_label_from_issue(project.full_name, issue.github_number, label)
      issue.update!(labels: Array(issue.labels) - [ label ])
    rescue GithubClient::NotFoundError
      issue.update!(labels: Array(issue.labels) - [ label ])
    rescue GithubClient::Error => e
      log_github_failure("label_remove", e)
    end

    def comment_present?
      project.client.issue_comments(project.full_name, issue.github_number).any? do |comment|
        trusted_comment_author?(comment) && comment.body.to_s.include?(COMMENT_MARKER)
      end
    rescue GithubClient::Error => e
      log_github_failure("comment_lookup", e)
      true
    end

    def trusted_comment_author?(comment)
      login = comment.respond_to?(:user) ? comment.user&.login : nil
      project.paid_bot_author?(login) || project.trusted_github_user?(login)
    end

    def post_comment
      project.client.add_comment(
        project.full_name,
        issue.github_number,
        [ COMMENT_MARKER, "## Auto-enhancement stopped", "", reason, "", "Manual review is required before automation can continue." ].join("\n")
      )
    rescue GithubClient::Error => e
      log_github_failure("comment_post", e)
    end

    def log_github_failure(operation, error)
      Rails.logger.warn(
        message: "agent_execution.enhance_issue_manual_review_github_operation_failed",
        project_id: project.id,
        issue_id: issue.id,
        operation: operation,
        error_class: error.class.name,
        error: error.message
      )
    end
  end
end
