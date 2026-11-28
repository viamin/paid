# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128071130_remove_redundant_work_item_identity_indexes")

RSpec.describe RemoveRedundantWorkItemIdentityIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:tables) { %i[work_item_lifecycle_conflicts work_item_lifecycle_mappings work_item_project_mappings work_items work_item_project_mapping_targets] }
  let(:removed_names) { tables.reject { |table| table == :work_item_project_mapping_targets }.map { |table| "index_#{table}_on_account_id" } + [ "index_mapping_targets_on_mapping" ] }
  let(:fixture_indexes) do
    [
      %q{CREATE INDEX index_work_item_lifecycle_conflicts_on_account_id ON work_item_lifecycle_conflicts USING btree (account_id)},
      %q{CREATE INDEX index_work_item_lifecycle_conflicts_on_work_item_id ON work_item_lifecycle_conflicts USING btree (work_item_id)},
      %q{CREATE INDEX index_work_item_lifecycle_conflicts_on_resolved_by_id ON work_item_lifecycle_conflicts USING btree (resolved_by_id)},
      %q{CREATE INDEX index_lifecycle_conflicts_on_account_and_resolved ON work_item_lifecycle_conflicts USING btree (account_id, resolved_at)},
      %q{CREATE INDEX index_work_item_lifecycle_mappings_on_account_id ON work_item_lifecycle_mappings USING btree (account_id)},
      %q{CREATE INDEX index_work_item_lifecycle_mappings_on_project_id ON work_item_lifecycle_mappings USING btree (project_id)},
      %q{CREATE INDEX index_work_item_lifecycle_mappings_on_created_by_id ON work_item_lifecycle_mappings USING btree (created_by_id)},
      %q{CREATE UNIQUE INDEX index_lifecycle_mappings_on_native_state ON work_item_lifecycle_mappings USING btree (account_id, project_id, provider, native_state)},
      %q{CREATE UNIQUE INDEX index_lifecycle_mappings_on_account_native_state ON work_item_lifecycle_mappings USING btree (account_id, provider, native_state) WHERE (project_id IS NULL)},
      %q{CREATE UNIQUE INDEX index_lifecycle_mappings_on_paid_state ON work_item_lifecycle_mappings USING btree (account_id, project_id, provider, paid_state)},
      %q{CREATE UNIQUE INDEX index_lifecycle_mappings_on_account_paid_state ON work_item_lifecycle_mappings USING btree (account_id, provider, paid_state) WHERE (project_id IS NULL)},
      %q{CREATE UNIQUE INDEX index_work_item_project_mappings_on_native_identity ON work_item_project_mappings USING btree (account_id, provider, native_project_id)},
      %q{CREATE INDEX index_work_item_project_mappings_on_account_id ON work_item_project_mappings USING btree (account_id)},
      %q{CREATE INDEX index_work_item_project_mappings_on_tracker_configuration_id ON work_item_project_mappings USING btree (tracker_configuration_id)},
      %q{CREATE INDEX idx_on_default_execution_project_id_1e58c0e691 ON work_item_project_mappings USING btree (default_execution_project_id)},
      %q{CREATE INDEX index_work_item_project_mappings_on_created_by_id ON work_item_project_mappings USING btree (created_by_id)},
      %q{CREATE UNIQUE INDEX index_work_items_on_legacy_issue_id ON work_items USING btree (legacy_issue_id) WHERE (legacy_issue_id IS NOT NULL)},
      %q{CREATE INDEX index_work_items_on_account_id ON work_items USING btree (account_id)},
      %q{CREATE INDEX index_work_items_on_tracker_configuration_id ON work_items USING btree (tracker_configuration_id)},
      %q{CREATE UNIQUE INDEX index_work_items_on_provider_identity ON work_items USING btree (account_id, provider, resource_type, external_id)},
      %q{CREATE INDEX index_work_items_on_native_project_id ON work_items USING btree (native_project_id)},
      %q{CREATE INDEX index_mapping_targets_on_mapping ON work_item_project_mapping_targets USING btree (work_item_project_mapping_id)},
      %q{CREATE UNIQUE INDEX index_mapping_targets_on_mapping_and_project ON work_item_project_mapping_targets USING btree (work_item_project_mapping_id, project_id)},
      %q{CREATE INDEX index_work_item_project_mapping_targets_on_project_id ON work_item_project_mapping_targets USING btree (project_id)}
    ]
  end

  around do |example|
    schema = "pghero_work_identity_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_tables
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-025
  it "removes only the five redundant prefixes and preserves all other index definitions and rows" do
    original_indexes = indexes
    original_rows = rows
    2.times { migration.up }

    expect(indexes).to eq(original_indexes.transform_values { |definitions| definitions.except(*removed_names) })
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-025
  it "restores the original definitions on repeated rollback without changing rows" do
    original_indexes = indexes
    original_rows = rows
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-025
  it "preserves provider and native-project identity uniqueness within each account" do
    migration.up
    duplicates = [
      "INSERT INTO work_items (account_id, provider, resource_type, external_id) VALUES (1, 'linear', 'issue', 'ticket')",
      "INSERT INTO work_item_project_mappings (account_id, provider, native_project_id) VALUES (1, 'linear', 'proj')"
    ]
    duplicates.each { |sql| expect { connection.execute(sql) }.to raise_error(ActiveRecord::RecordNotUnique) }
    duplicates.each { |sql| expect { connection.execute(sql.sub("VALUES (1,", "VALUES (2,")) }.not_to raise_error }
  end

  # @spec POSTGRESQL-PERSISTENCE-025
  it "preserves both global and project lifecycle uniqueness while allowing an override" do
    migration.up

    expect { insert_mapping(nil, "Todo", "backlog") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { insert_mapping(nil, "Other", "open") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { insert_mapping(1, "Todo", "backlog") }.not_to raise_error
    expect { insert_mapping(1, "Todo", "other") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { insert_mapping(1, "Other", "backlog") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # @spec POSTGRESQL-PERSISTENCE-025
  it "retains usable conflict, lifecycle and provider identity lookup paths" do
    migration.up
    queries = {
      "work_item_lifecycle_conflicts WHERE account_id = 1 AND resolved_at IS NULL" => "index_lifecycle_conflicts_on_account_and_resolved",
      "work_item_lifecycle_mappings WHERE account_id = 1 AND project_id = 1 AND provider = 'linear' AND native_state = 'InProgress'" => %w[index_lifecycle_mappings_on_native_state index_lifecycle_mappings_on_paid_state],
      "work_item_project_mappings WHERE account_id = 1 AND provider = 'linear' AND native_project_id = 'proj'" => "index_work_item_project_mappings_on_native_identity",
      "work_item_project_mapping_targets WHERE work_item_project_mapping_id = 1" => "index_mapping_targets_on_mapping_and_project",
      "work_items WHERE account_id = 1 AND provider = 'linear' AND resource_type = 'issue' AND external_id = 'ticket'" => "index_work_items_on_provider_identity"
    }
    queries.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to match(Regexp.union(Array(index)))
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-025
  it "preserves unique mapping targets while allowing another project or mapping" do
    migration.up

    expect do
      connection.execute("INSERT INTO work_item_project_mapping_targets (work_item_project_mapping_id, project_id) VALUES (1, 1)")
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect do
      connection.execute("INSERT INTO work_item_project_mapping_targets (work_item_project_mapping_id, project_id) VALUES (1, 2), (2, 1)")
    end.not_to raise_error
  end

  def indexes
    tables.to_h do |table|
      [ table, connection.indexes(table).to_h { |index| [ index.name, [ index.columns, index.unique, index.where ] ] } ]
    end
  end

  def rows
    tables.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
  end

  def insert_mapping(project_id, native_state, paid_state)
    connection.execute(<<~SQL)
      INSERT INTO work_item_lifecycle_mappings (account_id, project_id, provider, native_state, paid_state)
      VALUES (1, #{connection.quote(project_id)}, 'linear', #{connection.quote(native_state)}, #{connection.quote(paid_state)})
    SQL
  end

  def prepare_tables
    connection.create_table(:work_item_lifecycle_conflicts) do |t|
      %i[account_id work_item_id resolved_by_id].each { |column| t.bigint column }
      t.timestamp :resolved_at
    end
    connection.create_table(:work_item_lifecycle_mappings) do |t|
      %i[account_id project_id created_by_id].each { |column| t.bigint column }
      %i[provider native_state paid_state].each { |column| t.string column }
    end
    connection.create_table(:work_item_project_mappings) do |t|
      %i[account_id tracker_configuration_id default_execution_project_id created_by_id].each { |column| t.bigint column }
      %i[provider native_project_id].each { |column| t.string column }
    end
    connection.create_table(:work_items) do |t|
      %i[account_id tracker_configuration_id legacy_issue_id].each { |column| t.bigint column }
      %i[native_project_id provider resource_type external_id].each { |column| t.string column }
    end
    connection.create_table(:work_item_project_mapping_targets) do |t|
      t.bigint :work_item_project_mapping_id
      t.bigint :project_id
    end
    fixture_indexes.each { |sql| connection.execute(sql) }
    connection.execute("INSERT INTO work_item_lifecycle_conflicts (account_id, work_item_id) VALUES (1, 1)")
    insert_mapping(nil, "Todo", "open")
    insert_mapping(1, "InProgress", "in_progress")
    connection.execute("INSERT INTO work_item_project_mappings (account_id, provider, native_project_id) VALUES (1, 'linear', 'proj')")
    connection.execute("INSERT INTO work_item_project_mapping_targets (work_item_project_mapping_id, project_id) VALUES (1, 1)")
    connection.execute("INSERT INTO work_items (account_id, provider, resource_type, external_id, legacy_issue_id) VALUES (1, 'linear', 'issue', 'ticket', 7)")
  end
end
