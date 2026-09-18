# frozen_string_literal: true

module Inbox
  # Resolves the GitHub URL of the enhancement-stopped comment
  # (IssueEnhancements::StopForManualReview's marker comment) so the
  # manual_review detail pane can link straight to the comment the state was
  # derived from, not just the issue. Returns nil whenever GitHub is
  # unavailable, the comment can't be found, or the lookup errors -- the
  # detail pane falls back to the issue link alone.
  # @spec OPERATOR-INBOX-002D
  class ManualReviewCommentLink
    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:)
      @project = project
      @issue = issue
    end

    def call
      return nil unless project.github_credential_present?

      matching_comment&.html_url
    rescue GithubClient::Error
      nil
    end

    private

    attr_reader :project, :issue

    def matching_comment
      project.client.issue_comments(project.full_name, issue.github_number).reverse.find do |comment|
        paid_bot_comment?(comment) && comment.body.to_s.include?(IssueEnhancements::StopForManualReview::COMMENT_MARKER)
      end
    end

    def paid_bot_comment?(comment)
      login = comment.respond_to?(:user) ? comment.user&.login : nil
      project.paid_bot_author?(login)
    end
  end
end
