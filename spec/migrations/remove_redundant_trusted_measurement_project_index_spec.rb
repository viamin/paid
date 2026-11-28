# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128084040_remove_redundant_trusted_measurement_project_index")

RSpec.describe RemoveRedundantTrustedMeasurementProjectIndex, :no_db do
  let(:migration) { described_class.new }

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes only the redundant project index concurrently" do
    expect(described_class.disable_ddl_transaction).to be(true)
    allow(migration).to receive(:remove_index)

    migration.up

    expect(migration).to have_received(:remove_index).with(
      :trusted_measurement_attempts,
      name: "index_trusted_measurement_attempts_on_project_id",
      algorithm: :concurrently
    )
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "restores the project index concurrently on rollback" do
    allow(migration).to receive(:add_index)

    migration.down

    expect(migration).to have_received(:add_index).with(
      :trusted_measurement_attempts,
      :project_id,
      name: "index_trusted_measurement_attempts_on_project_id",
      algorithm: :concurrently
    )
  end
end
