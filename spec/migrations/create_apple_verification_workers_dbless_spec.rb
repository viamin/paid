# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260919071226_create_apple_verification_workers")

RSpec.describe CreateAppleVerificationWorkers, :no_db do
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive(:table_exists?).and_return(true)
    allow(migration).to receive(:column_exists?).with(:projects, :apple_verification_mode).and_return(true)
    allow(migration).to receive(:check_constraint_exists?).with(:projects, name: "chk_projects_apple_verification_mode").and_return(true)
    allow(migration).to receive(:drop_table)
    allow(migration).to receive(:remove_check_constraint)
    allow(migration).to receive(:remove_column)
  end

  it "removes every object created by the migration in dependency order" do # @spec APPLE-WORKER-003 @spec APPLE-WORKER-005 @spec APPLE-WORKER-006
    migration.down

    expect(migration).to have_received(:drop_table).ordered.with(:apple_verification_waivers)
    expect(migration).to have_received(:drop_table).ordered.with(:apple_verification_attempts)
    expect(migration).to have_received(:drop_table).ordered.with(:apple_verification_workflow_revisions)
    expect(migration).to have_received(:drop_table).ordered.with(:apple_worker_profiles)
    expect(migration).to have_received(:remove_check_constraint)
      .with(:projects, name: "chk_projects_apple_verification_mode")
    expect(migration).to have_received(:remove_column).with(:projects, :apple_verification_mode)
  end
end
