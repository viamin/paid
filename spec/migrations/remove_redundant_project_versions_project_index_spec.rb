# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128091755_remove_redundant_project_versions_project_index")

RSpec.describe RemoveRedundantProjectVersionsProjectIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    restore_redundant_index
    example.run
  ensure
    restore_redundant_index
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes only the redundant project index and restores it on rollback" do
    expect(index(described_class::REDUNDANT_INDEX)).to be_present
    expect(covering_index.columns).to eq(%w[project_id committed_at])
    expect(covering_index.orders).to eq("committed_at" => :desc)
    expect(covering_index_valid?).to be(true)

    migration.up

    expect(index(described_class::REDUNDANT_INDEX)).to be_nil
    expect(covering_index.columns).to eq(%w[project_id committed_at])
    expect(covering_index.orders).to eq("committed_at" => :desc)
    expect(covering_index_valid?).to be(true)

    migration.down

    expect(index(described_class::REDUNDANT_INDEX).columns).to eq([ "project_id" ])
    expect(covering_index.columns).to eq(%w[project_id committed_at])
  end

  private

  def index(name)
    connection.indexes(:project_versions).find { |candidate| candidate.name == name }
  end

  def covering_index
    index("index_project_versions_on_project_id_and_committed_at")
  end

  def restore_redundant_index
    return if index(described_class::REDUNDANT_INDEX)

    connection.add_index :project_versions, :project_id,
      name: described_class::REDUNDANT_INDEX, algorithm: :concurrently
  end

  def covering_index_valid?
    connection.select_value(<<~SQL.squish)
      SELECT indisvalid
      FROM pg_index
      WHERE indexrelid = 'public.index_project_versions_on_project_id_and_committed_at'::regclass
    SQL
  end
end
