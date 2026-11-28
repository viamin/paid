# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128055841_remove_redundant_style_guide_test_indexes")

RSpec.describe RemoveRedundantStyleGuideTestIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:tables) { %i[style_guide_ab_test_variants style_guide_ab_tests style_guide_versions] }
  let(:removed_names) do
    %w[index_style_guide_ab_test_variants_on_style_guide_ab_test_id
      index_style_guide_ab_tests_on_style_guide_id index_style_guide_versions_on_style_guide_id]
  end

  around do |example|
    schema = "pghero_style_test_indexes_#{SecureRandom.hex(6)}"
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

  # @spec POSTGRESQL-PERSISTENCE-019
  it "removes exactly the three redundant indexes and preserves rows and other index definitions" do
    original_rows = rows
    retained = indexes.reject { |name, _| removed_names.include?(name) }

    2.times { migration.up }

    expect(indexes).to eq(retained)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-019
  it "restores each removed index on repeated rollback without changing rows or retained indexes" do
    original_indexes = indexes
    original_rows = rows
    migration.up

    2.times { migration.down }

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-019
  it "preserves variant, control, running-test and version uniqueness" do
    migration.up

    expect_unique_violation("INSERT INTO style_guide_ab_test_variants (style_guide_ab_test_id, style_guide_version_id, is_control) VALUES (1, 2, false)")
    connection.execute("INSERT INTO style_guide_ab_test_variants (style_guide_ab_test_id, style_guide_version_id, is_control) VALUES (1, 3, true)")
    expect_unique_violation("INSERT INTO style_guide_ab_test_variants (style_guide_ab_test_id, style_guide_version_id, is_control) VALUES (1, 4, true)")
    expect_unique_violation("INSERT INTO style_guide_ab_tests (account_id, style_guide_id, status) VALUES (1, 3, 'running')")
    expect_unique_violation("INSERT INTO style_guide_versions (style_guide_id, version, review_status) VALUES (1, 2, 'draft')")
  end

  # @spec POSTGRESQL-PERSISTENCE-019
  it "retains usable full index paths for test and guide lookups" do
    migration.up
    queries = {
      "style_guide_ab_test_variants WHERE style_guide_ab_test_id = 1" => %w[index_style_guide_ab_test_variants_on_test_and_version],
      "style_guide_ab_tests WHERE style_guide_id = 2" => %w[index_style_guide_ab_tests_on_style_guide_id_and_status],
      "style_guide_versions WHERE style_guide_id = 1" => %w[index_style_guide_versions_on_style_guide_id_and_version index_style_guide_versions_on_style_guide_id_and_review_status]
    }

    queries.each do |query, names|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{query}")
      end
      expect(plan).to match(Regexp.union(names))
    end
  end

  def indexes
    tables.flat_map { |table| connection.indexes(table) }.to_h do |index|
      [ index.name, [ index.columns, index.unique, index.where ] ]
    end
  end

  def rows
    tables.to_h { |table| [ table, connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ] }
  end

  def expect_unique_violation(sql)
    expect { connection.execute(sql) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  def prepare_tables
    prepare_variants
    prepare_tests
    prepare_versions
  end

  def prepare_variants
    connection.create_table(:style_guide_ab_test_variants) do |table|
      table.bigint :style_guide_ab_test_id
      table.bigint :style_guide_version_id
      table.boolean :is_control
    end
    connection.add_index :style_guide_ab_test_variants, [ :style_guide_ab_test_id, :style_guide_version_id ],
      name: "index_style_guide_ab_test_variants_on_test_and_version", unique: true
    connection.add_index :style_guide_ab_test_variants, :style_guide_ab_test_id,
      name: "index_style_guide_ab_test_variants_on_control_per_test", unique: true, where: "is_control = true"
    connection.add_index :style_guide_ab_test_variants, :style_guide_ab_test_id
    connection.add_index :style_guide_ab_test_variants, :style_guide_version_id
    connection.execute("INSERT INTO style_guide_ab_test_variants (style_guide_ab_test_id, style_guide_version_id, is_control) VALUES (1, 2, false)")
  end

  def prepare_tests
    connection.create_table(:style_guide_ab_tests) do |table|
      table.bigint :account_id
      table.bigint :style_guide_id
      table.string :status
    end
    connection.add_index :style_guide_ab_tests, [ :style_guide_id, :status ]
    connection.add_index :style_guide_ab_tests, :account_id,
      name: "index_style_guide_ab_tests_one_running_per_account", unique: true, where: "status = 'running'"
    connection.add_index :style_guide_ab_tests, :style_guide_id
    connection.execute("INSERT INTO style_guide_ab_tests (account_id, style_guide_id, status) VALUES (1, 2, 'running')")
  end

  def prepare_versions
    connection.create_table(:style_guide_versions) do |table|
      table.bigint :style_guide_id
      table.integer :version
      table.string :review_status
    end
    connection.add_index :style_guide_versions, [ :style_guide_id, :version ], unique: true
    connection.add_index :style_guide_versions, [ :style_guide_id, :review_status ]
    connection.add_index :style_guide_versions, :style_guide_id
    connection.execute("INSERT INTO style_guide_versions (style_guide_id, version, review_status) VALUES (1, 2, 'approved')")
  end
end
