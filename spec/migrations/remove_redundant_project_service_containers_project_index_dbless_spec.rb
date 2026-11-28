# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128083333_remove_redundant_project_service_containers_project_index")

RSpec.describe RemoveRedundantProjectServiceContainersProjectIndex, :no_db do
  let(:migration) { described_class.new }

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes only the project lookup index concurrently and restores it on rollback" do
    expect(described_class.disable_ddl_transaction).to be(true)

    allow(migration).to receive(:remove_index)
    migration.up

    expect(migration).to have_received(:remove_index).with(
      :project_service_containers,
      name: "index_project_service_containers_on_project_id",
      algorithm: :concurrently,
      if_exists: true
    )

    allow(migration).to receive(:add_index)
    migration.down

    expect(migration).to have_received(:add_index).with(
      :project_service_containers,
      :project_id,
      name: "index_project_service_containers_on_project_id",
      algorithm: :concurrently,
      if_not_exists: true
    )
  end
end
