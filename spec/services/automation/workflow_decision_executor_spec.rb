# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::WorkflowDecisionExecutor do
  describe ".call" do
    let(:workflow) { instance_double(Workflows::GitHubPollWorkflow) }
    let(:logger) { instance_double(Logger, warn: true) }

    before do
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)
    end

    it "warns when a decision type is not implemented in the executor" do
      described_class.call(workflow:, project_id: 1, result: {
        decisions: [ { type: "future_decision_type" } ]
      })

      expect(logger).to have_received(:warn).with(
        message: "workflow_decision_executor.unknown_decision_type",
        type: "future_decision_type"
      )
    end
  end
end
