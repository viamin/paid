# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationBundleRetentionSweepJob do
  # @spec APPLE-TRANSFER-006
  it "runs the Apple verification bundle and VM retention sweep" do
    expect(AppleVerification::Bundles::RetentionSweep).to receive(:call)

    described_class.perform_now
  end
end
