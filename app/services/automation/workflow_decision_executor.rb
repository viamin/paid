# frozen_string_literal: true

module Automation
  class WorkflowDecisionExecutor
    def self.call(workflow:, project_id:, result:)
      new(workflow:, project_id:).call(result)
    end

    def initialize(workflow:, project_id:)
      @workflow = workflow
      @project_id = project_id
    end

    def call(result)
      Array(result[:decisions]).each do |decision|
        execute(decision.deep_symbolize_keys)
      end
    end

    private

    attr_reader :workflow, :project_id

    def execute(decision)
      workflow.execute_automation_decision(project_id:, decision:)
    end
  end
end
