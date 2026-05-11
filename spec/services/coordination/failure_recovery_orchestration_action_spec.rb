# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::FailureRecovery, :no_db do
  describe "#orchestration_action_for" do
    it "preserves unknown actions and logs a warning" do
      agent_run = Struct.new(:id).new(42)
      service = described_class.new(agent_run: agent_run, policy_overrides: {})
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
end
