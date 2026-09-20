# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260919072053_add_apple_verification_attempt_foreign_keys")

RSpec.describe AddAppleVerificationAttemptForeignKeys, :no_db do
  it "removes Apple attempt foreign keys" do # @spec APPLE-WORKER-007
    migration = described_class.new
    allow(migration).to receive(:foreign_key_exists?).and_return(true)
    allow(migration).to receive(:remove_foreign_key)

    migration.down

    expect(migration).to have_received(:remove_foreign_key)
      .with(:execution_audit_events, :apple_verification_attempts)
    expect(migration).to have_received(:remove_foreign_key)
      .with(:execution_resource_ledger_entries, :apple_verification_attempts)
  end
end
