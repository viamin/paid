# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::WorkflowDecisionExecutor do
  describe ".call" do
    let(:workflow) { instance_double(Workflows::GitHubPollWorkflow) }

    before do
      allow(workflow).to receive(:execute_automation_decision)
    end

    it "delegates concrete decisions to the workflow decision entrypoint" do
      described_class.call(workflow:, project_id: 1, result: {
        decisions: [ { "type" => "dispatch_claude_review", "pr_number" => 42 } ]
      })

      expect(workflow).to have_received(:execute_automation_decision).with(
        project_id: 1,
        decision: { type: "dispatch_claude_review", pr_number: 42 }
      )
    end

    it "delegates unknown decisions to the workflow decision entrypoint" do
      described_class.call(workflow:, project_id: 1, result: {
        decisions: [ { type: "future_decision_type" } ]
      })

      expect(workflow).to have_received(:execute_automation_decision).with(
        project_id: 1,
        decision: { type: "future_decision_type" }
      )
    end
  end
end
