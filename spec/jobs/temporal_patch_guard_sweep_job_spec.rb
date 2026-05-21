# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemporalPatchGuardSweepJob do
  describe "#perform" do
    let(:sweep) { instance_double(TemporalPatchGuards::Sweep) }
    let(:report) do
      instance_double(
        TemporalPatchGuards::Report,
        workflow_summaries: [ { workflow_type: "Workflows::GitHubPollWorkflow", eligible_guard_names: [ "guard-a" ] } ],
        eligible_guards: [ instance_double(TemporalPatchGuards::GuardStatus, name: "guard-a", workflow_type: "Workflows::GitHubPollWorkflow") ]
      )
    end

    before do
      allow(TemporalPatchGuards::Sweep).to receive(:new).and_return(sweep)
      allow(sweep).to receive(:call).and_return(report)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:error)
    end

    it "logs a warning when eligible guards are found" do
      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "temporal.patch_guard_sweep.eligible_guards",
          eligible_guard_names: [ "guard-a" ]
        )
      )
    end

    it "re-raises sweep failures after logging" do
      allow(sweep).to receive(:call).and_raise(StandardError, "Temporal unavailable")

      expect {
        described_class.perform_now
      }.to raise_error(StandardError, "Temporal unavailable")

      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "temporal.patch_guard_sweep.failed",
          error: "Temporal unavailable"
        )
      )
    end
  end
end
