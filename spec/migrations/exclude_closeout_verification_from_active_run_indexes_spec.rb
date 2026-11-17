# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117073554_exclude_closeout_verification_from_active_run_indexes")

RSpec.describe ExcludeCloseoutVerificationFromActiveRunIndexes do
  let(:migration) { described_class.new }

  # @spec STAGED-CLOSEOUT-ADOPTION-008 STAGED-CLOSEOUT-ADOPTION-009
  it "refuses rollback before removing indexes when admitted runs conflict with the legacy keys" do
    allow(migration).to receive(:legacy_index_conflicts?).and_return(true)
    allow(migration).to receive(:remove_index)

    expect { migration.down }.to raise_error(
      ActiveRecord::IrreversibleMigration,
      /retain at most one active closeout-verification run/
    )
    expect(migration).not_to have_received(:remove_index)
  end
end
