# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-001
RSpec.describe CaptureAgentRunSessionSummaryJob do
  let(:agent_run) { create(:agent_run, :completed) }

  describe "#perform" do
    it "captures a session summary for the agent run" do
      allow(Knowledge::SessionSummaries::Capture).to receive(:call)

      described_class.perform_now(agent_run.id)

      expect(Knowledge::SessionSummaries::Capture).to have_received(:call).with(agent_run: agent_run)
    end

    it "does nothing when the agent run no longer exists" do
      allow(Knowledge::SessionSummaries::Capture).to receive(:call)
      missing_id = agent_run.id
      agent_run.destroy!

      described_class.perform_now(missing_id)

      expect(Knowledge::SessionSummaries::Capture).not_to have_received(:call)
    end

    it "swallows and logs errors instead of raising" do
      allow(Knowledge::SessionSummaries::Capture).to receive(:call).and_raise(StandardError, "boom")

      expect { described_class.perform_now(agent_run.id) }.not_to raise_error
    end
  end
end
