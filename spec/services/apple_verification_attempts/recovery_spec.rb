# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Recovery do
  # @spec APPLE-ATTEMPT-014
  it "reconciles resources before checking overdue attempts" do
    reconciler = class_double(ExecutionRunners::ResourceReconciler)
    timeout_monitor = class_double(AppleVerificationAttempts::TimeoutMonitor)
    allow(reconciler).to receive(:call).and_return(:reconciled)
    allow(timeout_monitor).to receive(:call).and_return([ :timed_out ])

    result = described_class.call(reconciler:, timeout_monitor:)

    expect(result).to have_attributes(reconciliation: :reconciled, timed_out_attempts: [ :timed_out ])
  end
end
