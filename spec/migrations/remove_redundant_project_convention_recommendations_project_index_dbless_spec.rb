# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128074249_remove_redundant_project_convention_recommendations_project_index")

RSpec.describe RemoveRedundantProjectConventionRecommendationsProjectIndex, :no_db do
  let(:migration) { described_class.new }

  it "removes only the redundant project index without blocking writes" do # @spec POSTGRESQL-PERSISTENCE-014
    expect(described_class.disable_ddl_transaction).to be true
    allow(migration).to receive(:remove_index)

    migration.up

    expect(migration).to have_received(:remove_index).with(
      :project_convention_recommendations,
      name: described_class::REDUNDANT_INDEX,
      algorithm: :concurrently,
      if_exists: true
    )
  end

  it "restores the single-column index concurrently on rollback" do # @spec POSTGRESQL-PERSISTENCE-014
    allow(migration).to receive(:add_index)

    migration.down

    expect(migration).to have_received(:add_index).with(
      :project_convention_recommendations,
      :project_id,
      name: described_class::REDUNDANT_INDEX,
      algorithm: :concurrently,
      if_not_exists: true
    )
  end
end
