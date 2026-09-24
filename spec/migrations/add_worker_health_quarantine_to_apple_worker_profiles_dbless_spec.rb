# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260923001829_add_worker_health_quarantine_to_apple_worker_profiles")

# @spec APPLE-ATTEMPT-015
RSpec.describe AddWorkerHealthQuarantineToAppleWorkerProfiles, :no_db do
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive_messages(index_exists?: true, foreign_key_exists?: true)
  end

  it "adds every missing quarantine column after a partial migration" do
    allow(migration).to receive(:column_exists?).and_return(false)
    allow(migration).to receive(:column_exists?)
      .with(:apple_worker_profiles, :consecutive_health_failures)
      .and_return(true)
    allow(migration).to receive(:add_column)

    migration.up

    expect(migration).not_to have_received(:add_column)
      .with(:apple_worker_profiles, :consecutive_health_failures, anything, anything)
    expect(migration).to have_received(:add_column)
      .with(:apple_worker_profiles, :last_health_failure_at, :datetime, anything)
    expect(migration).to have_received(:add_column)
      .with(:apple_worker_profiles, :quarantined_at, :datetime, anything)
    expect(migration).to have_received(:add_column)
      .with(:apple_worker_profiles, :quarantine_reason, :text, anything)
    expect(migration).to have_received(:add_column)
      .with(:apple_worker_profiles, :returned_to_service_at, :datetime, anything)
    expect(migration).to have_received(:add_column)
      .with(:apple_worker_profiles, :returned_to_service_by_id, :bigint, anything)
  end

  it "removes only quarantine columns that remain during a partial rollback" do
    allow(migration).to receive_messages(
      index_exists?: false,
      foreign_key_exists?: false,
      column_exists?: false
    )
    allow(migration).to receive(:column_exists?)
      .with(:apple_worker_profiles, :quarantine_reason)
      .and_return(true)
    allow(migration).to receive(:remove_column)

    migration.down

    expect(migration).to have_received(:remove_column)
      .with(:apple_worker_profiles, :quarantine_reason)
    expect(migration).to have_received(:remove_column).once
  end
end
