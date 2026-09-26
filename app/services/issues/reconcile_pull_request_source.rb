# frozen_string_literal: true

module Issues
  # Restores a PR's source issue only when its completed implementation-run
  # history has one unambiguous source. Conflicting historical records are
  # intentionally left for an operator rather than guessed.
  class ReconcilePullRequestSource
    def self.call(...)
      new(...).call
    end

    def initialize(pull_request:)
      @pull_request = pull_request
    end

    def call # @spec EAGER-QUEUE-009 EAGER-QUEUE-010
      return pull_request unless pull_request.is_pull_request?
      return pull_request if pull_request.parent_issue_id.present?

      source = sources.first
      return pull_request unless source
      return conflict unless sources.one?

      pull_request.update!(parent_issue: source)
      pull_request
    end

    private

    attr_reader :pull_request

    def sources
      pull_request.project.agent_runs
        .where(status: "completed", goal: "create_pr", pull_request_number: pull_request.github_number)
        .includes(issue: :parent_issue)
        .filter_map { |run| source_issue(run.issue) }
        .uniq
    end

    def source_issue(issue)
      return unless issue

      issue.is_pull_request? ? issue.parent_issue : issue
    end

    def conflict
      log_conflict
      pull_request
    end

    def log_conflict
      Rails.logger.warn(
        message: "github_sync.pull_request_source_conflict",
        project_id: pull_request.project_id,
        pull_request_id: pull_request.id,
        pull_request_number: pull_request.github_number
      )
    end
  end
end
