# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128081910_remove_project_mcp_servers_project_id_index")

RSpec.describe RemoveProjectMcpServersProjectIdIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    create_legacy_index
    example.run
  ensure
    drop_legacy_index
    create_covering_index
    connection.schema_cache.clear!
  end

  it "drops the covered project_id index without blocking writes" do # @spec POSTGRESQL-PERSISTENCE-014
    expect(described_class.disable_ddl_transaction).to be(true)

    expect { migration.up }.not_to raise_error

    expect(legacy_index).to be_nil
    expect(covering_index).not_to be_nil
    expect(covering_index.unique).to be(true)
    expect(covering_index.columns).to eq(%w[project_id mcp_server_definition_id])
  end

  it "re-creates the covered project_id index on rollback" do # @spec POSTGRESQL-PERSISTENCE-014
    migration.up

    expect { migration.down }.not_to raise_error

    expect(legacy_index).not_to be_nil
    expect(legacy_index.columns).to eq(%w[project_id])
  end

  it "leaves the catalog untouched when the covered index is already absent" do # @spec POSTGRESQL-PERSISTENCE-014
    drop_legacy_index

    expect { migration.up }.not_to raise_error

    expect(legacy_index).to be_nil
    expect(covering_index).not_to be_nil
  end

  it "keeps the covered index when the covering index is missing" do # @spec POSTGRESQL-PERSISTENCE-014
    drop_covering_index

    expect { migration.up }.not_to raise_error

    expect(legacy_index).not_to be_nil
  end

  private

  def legacy_index
    connection.indexes(:project_mcp_servers).find { |candidate| candidate.name == described_class::INDEX_NAME }
  end

  def covering_index
    connection.indexes(:project_mcp_servers).find { |candidate| candidate.name == described_class::COVERING_INDEX_NAME }
  end

  def create_legacy_index
    drop_legacy_index
    connection.add_index :project_mcp_servers, :project_id, name: described_class::INDEX_NAME
    connection.schema_cache.clear!
  end

  def drop_legacy_index
    connection.remove_index :project_mcp_servers, name: described_class::INDEX_NAME if legacy_index
    connection.schema_cache.clear!
  end

  def drop_covering_index
    connection.remove_index :project_mcp_servers, name: described_class::COVERING_INDEX_NAME if covering_index
    connection.schema_cache.clear!
  end

  def create_covering_index
    connection.add_index :project_mcp_servers, [ :project_id, :mcp_server_definition_id ],
      unique: true, name: described_class::COVERING_INDEX_NAME unless covering_index
    connection.schema_cache.clear!
  end
end
