# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128110204_remove_redundant_service_container_metrics_index")

RSpec.describe RemoveRedundantServiceContainerMetricsIndex do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:redundant_index) { described_class::REDUNDANT_INDEX }
  let(:covering_index) { described_class::COVERING_INDEX }

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes the redundant index, retains the covering lookup path, and restores it on rollback" do
    migration.up

    expect(index_names).not_to include(redundant_index)
    expect(index_columns(covering_index)).to eq(%w[service_container_id recorded_at])
    expect(lookup_plan).to include(covering_index)

    migration.down

    expect(index_columns(redundant_index)).to eq(%w[service_container_id])

    migration.up

    expect(index_names).not_to include(redundant_index)
    expect(index_columns(covering_index)).to eq(%w[service_container_id recorded_at])
  ensure
    migration.up if index_names.include?(redundant_index)
  end

  private

  def index_names
    connection.indexes(:service_container_metrics).map(&:name)
  end

  def index_columns(name)
    connection.indexes(:service_container_metrics).find { |index| index.name == name }.columns
  end

  def lookup_plan
    TenantContext.with_system_access do
      connection.select_values(<<~SQL.squish).join("\n")
        EXPLAIN (COSTS OFF)
        SELECT * FROM service_container_metrics
        WHERE service_container_id = -1
      SQL
    end
  end
end
