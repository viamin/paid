# frozen_string_literal: true

module Issues
  # Repairs the convenience PR-to-source relationship from the durable record
  # of the run that produced the PR. Conflicting historical records are left
  # untouched: selecting a source by recency would turn bad data into a wrong
  # dependency link.
  class ReconcilePullRequestSource
    def self.call(...)
      new(...).call
    end

    def initialize(pull_request)
      @pull_request = pull_request
    end

    def call # @spec EAGER-QUEUE-009
      return pull_request unless pull_request.is_pull_request?

      source_issue = unambiguous_source_issue
      return pull_request unless source_issue
      return pull_request if pull_request.parent_issue_id == source_issue.id
      return pull_request if pull_request.parent_issue_id.present?

      pull_request.update!(parent_issue: source_issue)
      pull_request
    end

    private

    attr_reader :pull_request

    def unambiguous_source_issue
      source_ids = pull_request.project.agent_runs
        .where(goal: "create_pr", status: "completed", pull_request_number: pull_request.github_number)
        .where.not(issue_id: nil)
        .joins(:issue)
        .merge(Issue.where(is_pull_request: false))
        .distinct
        .pluck(:issue_id)
      return if source_ids.size != 1

      Issue.find_by(id: source_ids.first, project_id: pull_request.project_id)
    end
  end
end
