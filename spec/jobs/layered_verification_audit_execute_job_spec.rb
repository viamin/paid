# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationAuditExecuteJob do
  # @spec LAYERED-VERIFY-020
  it "records an explicit failed audit outcome when execution raises" do
    audit = create(:layered_verification_audit, status: "dispatched")
    allow(LayeredVerification::Audits::Execute).to receive(:call).and_raise(StandardError, "unavailable")
    allow(audit.agent_run).to receive(:fail!)

    expect { described_class.perform_now(audit.id) }.to raise_error(StandardError, "unavailable")

    expect(audit.reload).to have_attributes(status: "failed", waiting_reason: "the audit could not be completed")
  end
end
