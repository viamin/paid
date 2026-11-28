# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128060847_remove_redundant_token_usage_indexes")

RSpec.describe RemoveRedundantTokenUsageIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:retained_indexes) do
    {
      "idx_token_usages_knowledge_run_created_at" => [ :knowledge_run_id, :created_at ],
      "idx_token_usages_request_type_created_at" => [ :request_type, :created_at ],
      "idx_token_usages_agent_run_created_at" => [ :agent_run_id, :created_at ],
      "index_token_usages_on_agent_run_id_and_request_type" => [ :agent_run_id, :request_type ],
      "index_token_usages_on_chat_session_id" => [ :chat_session_id ],
      "index_token_usages_on_created_at" => [ :created_at ],
      "index_token_usages_on_llm_model" => [ :llm_model ]
    }
  end

  around do |example|
    schema = "pghero_usage_indexes_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_usage_table
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-020
  it "removes both redundant indexes while preserving all retained indexes and usage rows" do
    original_rows = rows

    2.times { migration.up }

    expect(indexes).to eq(retained_indexes.transform_values { |columns| columns.map(&:to_s) })
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-020
  it "restores the original indexes and preserves rows on repeated rollback" do
    original_indexes = indexes
    original_rows = rows
    migration.up

    2.times { migration.down }

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-020
  it "preserves stored cost and token totals by request type" do
    migration.up

    totals = connection.select_rows(<<~SQL)
      SELECT request_type, SUM(cost_cents), SUM(input_tokens), SUM(output_tokens)
      FROM token_usages GROUP BY request_type ORDER BY request_type
    SQL
    expect(totals).to eq([ [ "agent", 31, 20, 12 ], [ "knowledge", 27, 17, 11 ] ])
  end

  # @spec POSTGRESQL-PERSISTENCE-020
  it "retains usable index paths for knowledge-run and request-type lookups" do
    migration.up
    { "knowledge_run_id = 1" => "idx_token_usages_knowledge_run_created_at",
      "request_type = 'knowledge'" => "idx_token_usages_request_type_created_at" }.each do |predicate, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM token_usages WHERE #{predicate}")
      end
      expect(plan).to include(index)
    end
  end

  def indexes
    connection.indexes(:token_usages).to_h { |index| [ index.name, index.columns ] }
  end

  def rows
    connection.select_all("SELECT * FROM token_usages ORDER BY id").to_a
  end

  def prepare_usage_table
    connection.create_table(:token_usages) do |table|
      table.bigint :knowledge_run_id
      table.bigint :agent_run_id
      table.bigint :chat_session_id
      table.string :request_type
      table.string :llm_model
      table.timestamp :created_at
      table.integer :cost_cents
      table.integer :input_tokens
      table.integer :output_tokens
    end
    retained_indexes.each { |name, columns| connection.add_index :token_usages, columns, name: name }
    %i[knowledge_run_id request_type].each { |column| connection.add_index :token_usages, column }
    connection.execute(<<~SQL)
      INSERT INTO token_usages (knowledge_run_id, agent_run_id, request_type, llm_model, created_at, cost_cents, input_tokens, output_tokens)
      VALUES (1, NULL, 'knowledge', 'fixture', '2026-11-01', 27, 17, 11),
             (NULL, 2, 'agent', 'fixture', '2026-11-02', 31, 20, 12)
    SQL
  end
end
