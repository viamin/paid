# frozen_string_literal: true

module ClarifyingQuestions
  # Clears an issue's "needs input" marker once its clarifying questions have
  # been answered: removes the needs-input label on GitHub and resets
  # paid_state so the "Answer Questions" button disappears and the issue
  # re-enters the pipeline.
  #
  # Idempotent (a no-op unless the issue is currently awaiting input) and
  # best-effort: a GitHub failure is logged but still updates local state, and
  # the next sync reconciles the label via
  # FetchIssuesActivity#detect_needs_input_label_removals. The label removed is
  # the enhancement needs-input label (what EnhanceIssueActivity adds and what
  # Issue#needs_input? checks), not the no-output label.
  class ClearNeedsInput
    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:)
      @project = project
      @issue = issue
    end

    def call
      return unless issue.needs_input?

      label = project.enhance_issue_needs_input_label_name
      remove_label(label)
      issue.update!(paid_state: "new", labels: Array(issue.labels) - [ label ])
    end

    private

    attr_reader :project, :issue

    def remove_label(label)
      project.client&.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "clarifying_questions.remove_needs_input_label_failed",
        issue_number: issue.github_number,
        label: label,
        error: e.message
      )
    end
  end
end
