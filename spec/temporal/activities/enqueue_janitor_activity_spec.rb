# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::EnqueueJanitorActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    it "enqueues an AgentRunResourceJanitorJob" do
      expect {
        activity.execute(agent_run_id: 42)
      }.to have_enqueued_job(AgentRunResourceJanitorJob).with(42)
    end

    it "returns the agent_run_id" do
      result = activity.execute(agent_run_id: 42)

      expect(result[:agent_run_id]).to eq(42)
    end

    it "does not enqueue a job when agent_run_id is nil" do
      expect {
        activity.execute(agent_run_id: nil)
      }.not_to have_enqueued_job(AgentRunResourceJanitorJob)
    end

    it "does not enqueue a job when agent_run_id is blank" do
      expect {
        activity.execute(agent_run_id: "")
      }.not_to have_enqueued_job(AgentRunResourceJanitorJob)
    end
  end
end
