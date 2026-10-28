# frozen_string_literal: true

module Notifications
  module Rules
    # @spec PR-LABEL-RECOVERY-003
    class InterruptedPullRequestPublication < Rule
      SOURCE = "interrupted_pull_request_publication"

      def self.candidates(project)
        project.issues
          .pull_requests_only
          .where(github_state: "open", pr_review_phase: %w[draft restarted])
          .where.not(parent_issue_id: nil)
          .joins(<<~SQL.squish)
            INNER JOIN agent_runs interrupted_publication_runs
              ON interrupted_publication_runs.issue_id = issues.parent_issue_id
             AND interrupted_publication_runs.goal = 'create_pr'
             AND interrupted_publication_runs.pull_request_number IS NULL
             AND interrupted_publication_runs.status IN (#{terminal_failure_statuses})
          SQL
          .distinct
      end

      private

      def self.terminal_failure_statuses
        AgentRun::TERMINAL_FAILURE_STATUSES.map { |status| ActiveRecord::Base.connection.quote(status) }.join(", ")
      end
      private_class_method :terminal_failure_statuses

      def source = SOURCE

      def detect(scope)
        Array(scope).select do |pull_request|
          pull_request.github_state == "open" && no_active_source_workflow?(pull_request)
        end
      end

      def resolve_candidates(scope)
        Array(scope)
      end

      def build(pull_request)
        run = interrupted_run_for(pull_request)
        {
          severity: :error,
          blocking: true,
          title: "PR ##{pull_request.github_number} was published but Paid did not finish reconciliation",
          description: "The create-PR run #{run.status} before recording this pull request.",
          nav_section: "projects",
          metadata: {
            source_issue_number: pull_request.parent_issue.github_number,
            agent_run_id: run.id,
            agent_run_status: run.status,
            pr_url: pull_request.github_url,
            recommended_action: "Review the open PR and decide whether to take over or retry Paid after resolving the failed run.",
            remediation_steps: [
              "Review the open pull request and its source issue.",
              "Resolve the failed or timed-out create-PR run before retrying Paid.",
              "Keep merge safeguards and any review hold in place until the PR is ready."
            ]
          }
        }
      end

      def no_active_source_workflow?(pull_request)
        !pull_request.parent_issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).exists?
      end

      def interrupted_run_for(pull_request)
        pull_request.parent_issue.agent_runs
          .where(goal: "create_pr", pull_request_number: nil, status: AgentRun::TERMINAL_FAILURE_STATUSES)
          .order(completed_at: :desc, id: :desc)
          .first!
      end
    end
  end
end
