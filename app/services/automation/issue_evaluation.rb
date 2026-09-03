# frozen_string_literal: true

module Automation
  class IssueEvaluation
    def self.call(project:, issue:, logger:)
      new(project:, issue:, logger:).call
    end

    def initialize(project:, issue:, logger:)
      @project = project
      @issue = issue
      @logger = logger
    end

    def call
      result = Automation::Evaluator.for(issue).call

      update_paid_state!(result)

      logger.info(
        message: "github_sync.detect_labels",
        project_id: project.id,
        issue_id: issue.id,
        decision_types: result.decisions.map(&:type)
      )

      serialize(result)
    end

    private

    attr_reader :project, :issue, :logger

    # @spec AUTOMATION-ACTIVATION-003
    def update_paid_state!(result)
      first_decision = result.decisions.reject { |decision| decision.type == "noop" }.first
      return unless first_decision

      new_state = case first_decision.type
      when "queue_create_pr_run"
        "in_progress"
      when "queue_analyze_issue_run"
        "in_progress"
      when "start_planning"
        "planning"
      end

      issue.update!(paid_state: new_state) if new_state
    end

    def serialize(result)
      serialized = result.to_h.merge(
        issue_id: issue.id,
        project_id: project.id,
        action: action_for(result)
      )

      if issue.is_pull_request? && serialized[:action] == "execute_agent"
        serialized[:source_pull_request_number] = issue.github_number
      end

      serialized
    end

    # @spec AUTOMATION-ACTIVATION-003
    def action_for(result)
      first_decision = result.decisions.reject { |decision| decision.type == "noop" }.first

      case first_decision&.type
      when "queue_create_pr_run"
        "execute_agent"
      when "queue_analyze_issue_run"
        "execute_agent"
      when "start_planning"
        "start_planning"
      else
        "none"
      end
    end
  end
end
