# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260919071227_add_apple_verification_attempt_references")

RSpec.describe AddAppleVerificationAttemptReferences, :no_db do
  it "removes Apple attempt references" do # @spec APPLE-WORKER-007
    migration = described_class.new
    allow(migration).to receive(:column_exists?).and_return(true)
    allow(migration).to receive(:remove_reference)

    migration.down

    expect(migration).to have_received(:remove_reference)
      .with(:execution_audit_events, :apple_verification_attempt, index: { algorithm: :concurrently })
    expect(migration).to have_received(:remove_reference)
      .with(:execution_resource_ledger_entries, :apple_verification_attempt, index: { algorithm: :concurrently })
  end
end
