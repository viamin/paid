# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127211815_remove_redundant_index_for_pg_hero5590")

RSpec.describe RemoveRedundantIndexForPgHero5590 do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:removed_columns) do
    {
      "index_knowledge_chunks_on_project_id" => %w[project_id],
      "index_knowledge_chunks_on_project_id_and_status" => %w[project_id status]
    }
  end
  let(:covering_name) { "idx_knowledge_chunks_project_status_artifact_sequence" }

  def indexes
    connection.indexes(:knowledge_chunks).to_h { |index| [ index.name, index ] }
  end

  def definition(index)
    [ index.columns, index.unique, index.using, index.where, index.orders, index.opclasses, index.comment ]
  end

  before do
    removed_columns.each do |name, columns|
      connection.add_index :knowledge_chunks, columns, name: name, algorithm: :concurrently unless indexes.key?(name)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-022
  it "resolves both covered-index findings and restores both definitions on rollback" do
    original = removed_columns.keys.to_h { |name| [ name, definition(indexes.fetch(name)) ] }
    covering = definition(indexes.fetch(covering_name))
    count = connection.select_value("SELECT COUNT(*) FROM knowledge_chunks")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(indexes.keys & removed_columns.keys).to be_empty
    expect(definition(indexes.fetch(covering_name))).to eq(covering)
    expect(connection.select_value("SELECT COUNT(*) FROM knowledge_chunks")).to eq(count)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    expect(original.keys.to_h { |name| [ name, definition(indexes.fetch(name)) ] }).to eq(original)
  ensure
    removed_columns.each do |name, columns|
      connection.add_index :knowledge_chunks, columns, name: name, algorithm: :concurrently unless indexes.key?(name)
    end
  end
end
