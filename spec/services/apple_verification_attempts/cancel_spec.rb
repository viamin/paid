# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Cancel do
  # @spec APPLE-ATTEMPT-006
  # @spec APPLE-ATTEMPT-014
  # @spec APPLE-ATTEMPT-009
  describe ".call" do
    it "revokes credentials and retains the VM before cancelling and requesting ledger cleanup" do
      attempt = create(:apple_verification_attempt, :committed, status: "running")
      ledger_entry = create(
        :execution_resource_ledger_entry,
        :active,
        apple_verification_attempt: attempt,
        account: attempt.account,
        project: attempt.project,
        runner_type: "apple_tart",
        resource_kind: "verification_vm"
      )

      described_class.call(attempt: attempt)
      expect(attempt.reload).to have_attributes(
        status: "cancelled", failure_classification: "cancellation_or_timeout",
        finished_at: be_present
      )
      expect(attempt.container_retained_until).to be_within(2.seconds).of(1.hour.from_now)
      expect(ledger_entry.reload).to be_cleanup_pending
      expect(ExecutionAuditEvent.where(
        event_name: "apple_credential.revoked",
        apple_verification_attempt_id: attempt.id
      )).to exist
    end
  end
end
