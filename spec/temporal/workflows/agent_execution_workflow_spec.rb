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

  describe "#stale_pull_request_error?" do
    let(:workflow) { described_class.new }

    def activity_error_with_cause(cause)
      activity_err = Temporalio::Error::ActivityError.new(
        "activity failed",
        scheduled_event_id: 1,
        started_event_id: 2,
        identity: "",
        activity_type: "CloneRepo",
        activity_id: "1",
        retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE
      )
      # Use Ruby's raise/rescue to set the real cause
      begin
        begin
          raise cause
        rescue
          raise activity_err
        end
      rescue => e
        e
      end
    end

    it "returns true for ActivityError wrapping StalePullRequest ApplicationError" do
      cause = Temporalio::Error::ApplicationError.new("stale", type: "StalePullRequest")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:stale_pull_request_error?, error)).to be true
    end

    it "returns false for other ApplicationError types" do
      cause = Temporalio::Error::ApplicationError.new("conflict", type: "WorktreeConflict")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:stale_pull_request_error?, error)).to be false
    end

    it "returns false for errors without a cause" do
      error = RuntimeError.new("something went wrong")
      expect(workflow.send(:stale_pull_request_error?, error)).to be false
    end
  end
end
