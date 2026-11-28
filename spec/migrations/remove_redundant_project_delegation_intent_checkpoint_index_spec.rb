# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128080334_remove_redundant_project_delegation_intent_checkpoint_index")

# @spec POSTGRESQL-PERSISTENCE-014
RSpec.describe RemoveRedundantProjectDelegationIntentCheckpointIndex, :no_db do
  let(:migration) { described_class.new }

  it "removes the duplicate index concurrently and restores it on rollback" do
    allow(migration).to receive(:remove_index)
    allow(migration).to receive(:add_index)

    migration.up
    migration.down

    expect(migration).to have_received(:remove_index).with(
      :project_delegation_intent_checkpoints,
      name: "idx_on_feature_intent_id_529a7745bc",
      algorithm: :concurrently
    )
    expect(migration).to have_received(:add_index).with(
      :project_delegation_intent_checkpoints,
      :feature_intent_id,
      name: "idx_on_feature_intent_id_529a7745bc",
      algorithm: :concurrently
    )
  end
end
