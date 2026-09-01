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
  end

  describe "retry semantics" do
    # retry_on intercepts the error before ApplicationJob's rescue_from hook,
    # so the exhausted final attempt must notify explicitly via the block.
    # Drive the per-exception retry counter to its limit so the next attempt
    # is terminal.
    it "notifies the exception notifier when retries are exhausted" do
      notifier = instance_double(Paid::ExceptionNotifier)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:call)
      allow(Knowledge::SessionSummaries::Capture).to receive(:call).and_raise(StandardError, "boom")

      job = described_class.new(agent_run.id)
      job.exception_executions = { "[StandardError]" => 4 }

      expect { job.perform_now }.to raise_error(StandardError, "boom")

      expect(notifier).to have_received(:call).with(
        an_instance_of(StandardError),
        data: hash_including(subsystem: "knowledge")
      )
    end

    it "does not notify while retries remain" do
      notifier = instance_double(Paid::ExceptionNotifier)
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:call)
      allow(Knowledge::SessionSummaries::Capture).to receive(:call).and_raise(StandardError, "boom")

      job = described_class.new(agent_run.id)
      job.exception_executions = { "[StandardError]" => 0 }

      # Retries remain, so retry_on reschedules (the :test adapter records the
      # retry without running it) instead of invoking the terminal block.
      expect { job.perform_now }.not_to raise_error
      expect(notifier).not_to have_received(:call)
    end
  end
end
