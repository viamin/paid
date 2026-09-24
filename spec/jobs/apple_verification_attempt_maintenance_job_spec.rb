# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-004
# @spec APPLE-ATTEMPT-014
RSpec.describe AppleVerificationAttemptMaintenanceJob do
  it "runs attempt recovery from the scheduled maintenance path" do
    result = AppleVerificationAttempts::Recovery::Result.new(scanned: 1, reclassified: [ 42 ], orphans: { enqueued: 0 })
    allow(AppleVerificationAttempts::Recovery).to receive(:call).and_return(result)

    described_class.perform_now

    expect(AppleVerificationAttempts::Recovery).to have_received(:call)
  end
end
