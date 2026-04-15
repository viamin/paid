# frozen_string_literal: true

module Activities
  # Evaluates a synced GitHub record through the shared automation decision
  # layer and returns explicit decisions for the poll workflow to execute.
  class DetectLabelsActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      project = Project.find(project_id)
      issue = project.issues.find(issue_id)
      explicit_pr_decisions = FeatureFlags.explicit_pr_automation_decisions?(project:)
      result = Automation::Evaluator.for(issue, explicit_pr_decisions:).call

      update_paid_state!(issue, result)

      logger.info(
        message: "github_sync.detect_labels",
        project_id: project_id,
        issue_id: issue_id,
        decision_types: result.decisions.map(&:type)
      )

      serialize_result(result, issue, project_id:, issue_id:)
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    end

    private

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
