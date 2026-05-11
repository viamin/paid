# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::FailureRecovery, :no_db do
  def expect_failed_decision_recorded(orchestration_action:, error_class_name:)
    expect(OrchestrationDecision).to have_received(:record).with(
      project: project,
      issue: issue,
      agent_run: agent_run,
      decision_point: "coordination_failure_recovery",
      action: orchestration_action,
      status: "failed",
      signals: {
        failure_category: "timeout",
        chosen_action: "escalate_model"
      },
      result: hash_including(
        chosen_action: "escalate_model",
        error_class: error_class_name
      )
    )
  end

  let(:project) { Object.new }
  let(:issue) { Struct.new(:id).new(7) }
  let(:agent_run) { Struct.new(:id, :project, :issue).new(42, project, issue) }
  let(:service) { described_class.new(agent_run: agent_run, policy_overrides: {}) }

  describe "#orchestration_action_for" do
    it "preserves unknown actions and logs a warning" do
      allow(Rails.logger).to receive(:warn)

      result = service.send(:orchestration_action_for, "handoff_to_human")

      expect(result).to eq("handoff_to_human")
      expect(Rails.logger).to have_received(:warn).with(
        message: "coordination.unknown_orchestration_action",
        action: "handoff_to_human",
        agent_run_id: 42
      )
    end
  end

  describe "#persist_failed_decision" do
    before do
      stub_const("OrchestrationDecision", Class.new do
        def self.record(*)
        end
      end)
      allow(OrchestrationDecision).to receive(:record)
      allow(service).to receive(:build_decision_signals).with("timeout", "escalate_model").and_return(
        failure_category: "timeout",
        chosen_action: "escalate_model"
      )
    end

    it "records the mapped orchestration action for non-retry fallbacks" do
      error_class = Class.new(StandardError)
      error = error_class.new("Validation failed: chosen action is invalid")

      service.send(:persist_failed_decision, error, category: "timeout", action: "escalate_model")

      expect_failed_decision_recorded(orchestration_action: "escalate", error_class_name: error_class.name)
    end
  end
end
