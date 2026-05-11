# frozen_string_literal: true

require "rails_helper"

RSpec.describe FailureRecoveryDecisionJob, :no_db do
  describe "#perform" do
    let(:run_snapshot) do
      {
        "status" => "timeout",
        "error_message" => "Agent execution timed out",
        "providers_attempted" => [
          { "provider" => "anthropic", "success" => false }
        ]
      }
    end

    let(:agent_run_class) do
      Class.new do
        def self.find_by(id:)
        end
      end
    end

    before do
      stub_const("AgentRun", agent_run_class)
    end

    it "runs failure recovery for an existing agent run" do
      agent_run = Object.new
      allow(AgentRun).to receive(:find_by).with(id: 123).and_return(agent_run)
      allow(Coordination::FailureRecovery).to receive(:call)

      described_class.new.perform(123, run_snapshot)

      expect(Coordination::FailureRecovery).to have_received(:call).with(
        agent_run: agent_run,
        run_snapshot: {
          status: "timeout",
          error_message: "Agent execution timed out",
          providers_attempted: [
            { "provider" => "anthropic", "success" => false }
          ]
        }
      )
    end

    it "does nothing when the agent run no longer exists" do
      allow(AgentRun).to receive(:find_by).with(id: 123).and_return(nil)
      allow(Coordination::FailureRecovery).to receive(:call)

      described_class.new.perform(123, run_snapshot)

      expect(Coordination::FailureRecovery).not_to have_received(:call)
    end
  end
end
