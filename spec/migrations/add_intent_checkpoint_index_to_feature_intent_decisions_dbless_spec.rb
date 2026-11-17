# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117175320_add_intent_checkpoint_index_to_feature_intent_decisions")

RSpec.describe AddIntentCheckpointIndexToFeatureIntentDecisions, :no_db do
  let(:migration) { described_class.new }

  it "builds the checkpoint lookup index without blocking decision writes" do # @spec PROJECT-DELEGATION-002
    expect(described_class.disable_ddl_transaction).to be true
    allow(migration).to receive(:add_index)

    migration.change

    expect(migration).to have_received(:add_index).with(
      :feature_intent_decisions,
      :intent_checkpoint_id,
      algorithm: :concurrently
    )
  end
end
