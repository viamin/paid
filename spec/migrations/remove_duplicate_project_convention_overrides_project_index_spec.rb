# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128072056_remove_duplicate_project_convention_overrides_project_index")

RSpec.describe RemoveDuplicateProjectConventionOverridesProjectIndex, :aggregate_failures do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    migration.down
    example.run
  ensure
    migration.up
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes only the project_id index covered by the unique project-and-key index" do
    indexes = connection.indexes(:project_convention_overrides).index_by(&:name)

    expect(indexes.fetch(described_class::COVERING_INDEX_NAME).columns).to eq(%w[project_id key])
    expect(indexes.fetch(described_class::COVERING_INDEX_NAME).unique).to be(true)
    expect(indexes.fetch(described_class::REDUNDANT_INDEX_NAME).columns).to eq(["project_id"])

    migration.up

    indexes = connection.indexes(:project_convention_overrides).index_by(&:name)
    expect(indexes).not_to have_key(described_class::REDUNDANT_INDEX_NAME)
    expect(indexes.fetch(described_class::COVERING_INDEX_NAME).columns).to eq(%w[project_id key])
    expect(indexes.fetch(described_class::COVERING_INDEX_NAME).unique).to be(true)

    migration.down

    index = connection.indexes(:project_convention_overrides).find { |candidate| candidate.name == described_class::REDUNDANT_INDEX_NAME }
    expect(index.columns).to eq(["project_id"])
  end
end
