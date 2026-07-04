# frozen_string_literal: true

module Activities
  # Batch-evaluates multiple issues for a project in a single activity,
  # replacing the per-issue DetectLabelsActivity fan-out in the poll workflow.
  #
  # Each issue is evaluated through the same Automation::Evaluator pipeline
  # as DetectLabelsActivity, but without crossing the Temporal boundary per
  # issue. This eliminates ~100-300ms of task-queue overhead per issue.
  class EvaluateIssuesActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      issue_ids = input[:issue_ids]
      project = Project.find(project_id)

      results = with_periodic_heartbeat("evaluate_issues", project_id: project_id, issue_count: issue_ids.size) do
        issue_ids.each_with_index.filter_map do |issue_id, index|
          heartbeat("evaluate_issues.issue", project_id: project_id, issue_id: issue_id, index: index, total: issue_ids.size)
          evaluate_issue(project, issue_id)
        end
      end

      { results: results }
    end

    private

    def evaluate_issue(project, issue_id)
      issue = project.issues.find(issue_id)
      Automation::IssueEvaluation.call(project:, issue:, logger:)
    rescue ActiveRecord::RecordNotFound => e
      logger.warn(
        message: "evaluate_issues.issue_not_found",
        project_id: project.id,
        issue_id: issue_id,
        error: e.message
      )
      nil
    rescue GithubClient::RateLimitError => e
      # Catch per-issue so already-processed issues keep their results and
      # state mutations. Rate-limited issues are skipped (nil) and will be
      # re-evaluated on the next poll cycle, preserving partial-progress
      # semantics equivalent to the old per-issue activity fan-out.
      logger.warn(
        message: "evaluate_issues.rate_limited",
        project_id: project.id,
        issue_id: issue_id,
        error: e.message
      )
      nil
    end
  end
end
