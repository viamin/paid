# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127200239_remove_redundant_index_for_pg_hero5454")

RSpec.describe RemoveRedundantIndexForPgHero5454 do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:removed_columns) do
    { "index_agent_runs_on_project_id" => [ "project_id" ], "index_agent_runs_on_project_id_and_status" => [ "project_id", "status" ] }
  end
  let(:covering_name) { "index_agent_runs_on_project_status_completed_at" }

  def indexes
    connection.indexes(:agent_runs).to_h { |index| [ index.name, index ] }
  end

  def definition(index)
    [ index.columns, index.unique, index.using, index.where, index.orders, index.opclasses, index.comment ]
  end

  before do
    removed_columns.each do |name, columns|
      connection.add_index :agent_runs, columns, name: name, algorithm: :concurrently unless indexes.key?(name)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-022
  it "resolves both covered-index findings and restores both definitions on rollback" do
    original = removed_columns.keys.to_h { |name| [ name, definition(indexes.fetch(name)) ] }
    covering = definition(indexes.fetch(covering_name))
    count = connection.select_value("SELECT COUNT(*) FROM agent_runs")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(indexes.keys & removed_columns.keys).to be_empty
    expect(definition(indexes.fetch(covering_name))).to eq(covering)
    expect(connection.select_value("SELECT COUNT(*) FROM agent_runs")).to eq(count)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    expect(original.keys.to_h { |name| [ name, definition(indexes.fetch(name)) ] }).to eq(original)
  ensure
    removed_columns.each do |name, columns|
      connection.add_index :agent_runs, columns, name: name, algorithm: :concurrently unless indexes.key?(name)
    end
  end
end
