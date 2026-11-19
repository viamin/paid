# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveTargetCloseoutVerificationSweepJob do
  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "uses the current signal once and admits each active project through the live-target path" do
    first = create(:project)
    second = create(:project)
    allow(TrustedMeasurements::DeploymentSignal).to receive(:current).and_return("development:head:digest")

    expect(CloseoutVerifications::AdmitLiveTarget).to receive(:call)
      .with(project: first, target_revision: "development:head:digest")
    expect(CloseoutVerifications::AdmitLiveTarget).to receive(:call)
      .with(project: second, target_revision: "development:head:digest")

    described_class.perform_now
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "does not fabricate admission without an environment signal" do
    allow(TrustedMeasurements::DeploymentSignal).to receive(:current).and_return(nil)
    expect(CloseoutVerifications::AdmitLiveTarget).not_to receive(:call)

    described_class.perform_now
  end
end
