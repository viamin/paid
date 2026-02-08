# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::AgentExecutionWorkflow do
  let(:workflow) { described_class.new }

  describe "class" do
    it "inherits from BaseWorkflow" do
      expect(described_class.superclass).to eq(Workflows::BaseWorkflow)
    end

    it "is a Temporal workflow" do
      expect(described_class).to be < Temporalio::Workflow::Definition
    end
  end

  describe "#execute" do
    it "accepts project_id, issue_id, and optional agent_type parameters" do
      expect(workflow.method(:execute).parameters).to include(
        [ :keyreq, :project_id ],
        [ :keyreq, :issue_id ]
      )
    end

    it "has a default agent_type of claude_code" do
      params = workflow.method(:execute).parameters
      expect(params).to include([ :key, :agent_type ])
    end
  end

  describe "NO_RETRY_POLICY" do
    it "allows only one attempt" do
      policy = described_class::NO_RETRY_POLICY
      expect(policy).to be_a(Temporalio::RetryPolicy)
    end
  end
end
