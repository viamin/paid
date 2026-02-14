# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::AgentExecutionWorkflow do
  let(:workflow) { described_class.new }

  describe "class" do
    it "inherits from BaseWorkflow" do
      expect(described_class.superclass).to eq(Workflows::BaseWorkflow)
    end

    it "is a Temporal workflow definition" do
      expect(described_class).to be < Temporalio::Workflow::Definition
    end
  end

  describe "#execute" do
    it "accepts a single input parameter" do
      params = workflow.method(:execute).parameters
      expect(params).to eq([ [ :req, :input ] ])
    end
  end

  describe "NO_RETRY" do
    it "defines a no-retry policy with max_attempts of 1" do
      policy = described_class::NO_RETRY
      expect(policy).to be_a(Temporalio::RetryPolicy)
      expect(policy.max_attempts).to eq(1)
    end
  end
end
