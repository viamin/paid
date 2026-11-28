# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128102339_remove_redundant_prompt_versions_prompt_id_index")

RSpec.describe RemoveRedundantPromptVersionsPromptIdIndex, :aggregate_failures do
  # @spec POSTGRESQL-PERSISTENCE-014
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:covering_index_name) { "index_prompt_versions_on_prompt_id_and_version" }

  before { migration.down }
  after { migration.up }

  it "removes the redundant index, preserves its covering index, and restores it on rollback" do
    covering_index = index_definition(covering_index_name)
    expect(covering_index).to include("CREATE UNIQUE INDEX")
    expect(index_definition(described_class::INDEX_NAME)).to include("(prompt_id)")

    migration.up
    expect(index_definition(described_class::INDEX_NAME)).to be_nil
    expect(index_definition(covering_index_name)).to eq(covering_index)

    migration.down
    expect(index_definition(described_class::INDEX_NAME)).to include("(prompt_id)")

    migration.up
    expect(index_definition(described_class::INDEX_NAME)).to be_nil
    expect(index_definition(covering_index_name)).to eq(covering_index)
  end

  def index_definition(index_name)
    connection.select_value(<<~SQL.squish)
      SELECT indexdef
        FROM pg_indexes
       WHERE schemaname = ANY (current_schemas(false))
         AND tablename = 'prompt_versions'
         AND indexname = #{connection.quote(index_name)}
    SQL
  end
end
