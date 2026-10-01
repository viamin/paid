# frozen_string_literal: true

module Issues
  # Restores a PR's source issue only when its implementation-run history
  # has one unambiguous source. A run that recorded the PR's number counts
  # regardless of terminal status — the number is persisted at publication,
  # so the run can fail or be cancelled after the PR already exists.
  # Conflicting historical records are intentionally left for an operator
  # rather than guessed.
  class ReconcilePullRequestSource
    def self.call(...)
      new(...).call
    end

    # Read-only preview of what +call+ would link, for repair/reporting
    # tools (the `issues:repair_pull_request_source_links` rake task) that
    # need to distinguish an unambiguous match from a conflicting history
    # without writing. Mirrors +call+'s early-out: an already-linked PR has
    # nothing left to reconcile.
    def self.candidate_source_issues(pull_request) # @spec EAGER-QUEUE-012
      return [] if pull_request.parent_issue_id.present?

      new(pull_request: pull_request).sources
    end

    def initialize(pull_request:)
      @pull_request = pull_request
    end

    def call # @spec EAGER-QUEUE-009 EAGER-QUEUE-010
      return pull_request unless pull_request.is_pull_request?
      return pull_request if pull_request.parent_issue_id.present?

      matches = sources
      source = matches.first
      return pull_request unless source
      return conflict unless matches.one?

      pull_request.update!(parent_issue: source)
      pull_request
    end

    # `pull_request_number` alone can't distinguish a fork PR from an
    # upstream-synced PR that happens to land on the same number (GitHub PR
    # numbers are per-repo, so collisions are ordinary — see the comment on
    # CreatePullRequestActivity#missing_pull_request_numbers). The agent_run's
    # persisted `pull_request_url` is repo-qualified, so require it to match
    # this PR's actual GitHub URL before treating the run as evidence.
    def sources
      pull_request.project.agent_runs
        .where(goal: "create_pr", pull_request_number: pull_request.github_number, pull_request_url: pull_request.github_url)
        .includes(issue: :parent_issue)
        .filter_map { |run| source_issue(run.issue) }
        .uniq
    end

    private

    attr_reader :pull_request

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
