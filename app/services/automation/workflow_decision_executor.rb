# frozen_string_literal: true

module Automation
  class WorkflowDecisionExecutor
    def self.call(workflow:, project_id:, result:)
      new(workflow:, project_id:).call(result)
    end

    def initialize(workflow:, project_id:)
      @workflow = workflow
      @project_id = project_id
      @create_pr_queue_results = {}
    end

    def call(result)
      Array(result[:decisions]).each do |decision|
        execute(decision.deep_symbolize_keys)
      end
    end

    private

    attr_reader :workflow, :project_id

    def execute(decision)
      return skip_record_pr_followup?(decision) if decision[:type] == "record_pr_followup"

      result = workflow.execute_automation_decision(project_id:, decision:)
      record_create_pr_queue_result(decision, result)
      result
    end

    def record_create_pr_queue_result(decision, result)
      return unless decision[:type] == "queue_create_pr_run"

      @create_pr_queue_results[decision[:issue_id]] = result
    end

    def skip_record_pr_followup?(decision)
      issue_id = decision[:issue_id]
      return workflow.execute_automation_decision(project_id:, decision:) unless @create_pr_queue_results.key?(issue_id)

      queue_result = @create_pr_queue_results[issue_id]
      return nil if queue_result.nil?
      return workflow.execute_automation_decision(project_id:, decision:) if queue_result[:queued]
      return workflow.execute_automation_decision(project_id:, decision:) unless queue_result[:cross_goal]

      nil
    end
  end
end
