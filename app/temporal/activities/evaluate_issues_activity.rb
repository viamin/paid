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
      explicit_pr_decisions = FeatureFlags.explicit_pr_automation_decisions?(project:)

      results = issue_ids.filter_map do |issue_id|
        evaluate_issue(project, issue_id, explicit_pr_decisions:)
      end

      { results: results }
    end

    private

    def evaluate_issue(project, issue_id, explicit_pr_decisions:)
      issue = project.issues.find(issue_id)
      result = Automation::Evaluator.for(issue, explicit_pr_decisions:).call

      update_paid_state!(issue, result)

      logger.info(
        message: "github_sync.detect_labels",
        project_id: project.id,
        issue_id: issue_id,
        decision_types: result.decisions.map(&:type)
      )

      serialize_result(result, issue, project_id: project.id, issue_id:)
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

    def update_paid_state!(issue, result)
      first_decision = result.decisions.reject { |decision| decision.type == "noop" }.first
      return unless first_decision

      new_state = case first_decision.type
      when "queue_create_pr_run"
        "in_progress"
      when "start_planning"
        "planning"
      end

      issue.update!(paid_state: new_state) if new_state
    end

    def serialize_result(result, issue, project_id:, issue_id:)
      serialized = result.to_h.merge(
        issue_id: issue_id,
        project_id: project_id,
        action: action_for(result)
      )

      if issue.is_pull_request? && serialized[:action] == "execute_agent"
        serialized[:source_pull_request_number] = issue.github_number
      end

      serialized
    end

    def action_for(result)
      first_decision = result.decisions.reject { |decision| decision.type == "noop" }.first

      case first_decision&.type
      when "queue_create_pr_run"
        "execute_agent"
      when "start_planning"
        "start_planning"
      else
        "none"
      end
    end
  end
end
