# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128092459_remove_redundant_quality_metric_indexes")

RSpec.describe RemoveRedundantQualityMetricIndexes do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:removed_names) { %w[index_quality_metrics_on_agent_run_id index_quality_metrics_on_prompt_version_id] }

  around do |example|
    schema = "pghero_quality_metrics_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      prepare_table
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-028
  it "removes only the redundant prefixes and preserves metric data and other index definitions" do
    original_indexes = indexes
    original_rows = rows
    2.times { migration.up }

    expect(indexes).to eq(original_indexes.except(*removed_names))
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-028
  it "restores exact original definitions on repeated rollback without changing scores" do
    original_indexes = indexes
    original_rows = rows
    migration.up
    2.times { migration.down }

    expect(indexes).to eq(original_indexes)
    expect(rows).to eq(original_rows)
  end

  # @spec POSTGRESQL-PERSISTENCE-028
  it "preserves one metric per run and type while allowing another type or run" do
    migration.up
    duplicate = "INSERT INTO quality_metrics (agent_run_id, metric_type) VALUES (1, 'automated')"

    expect { connection.execute(duplicate) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { connection.execute(duplicate.sub("'automated'", "'human'")) }.not_to raise_error
    expect { connection.execute(duplicate.sub("VALUES (1,", "VALUES (3,")) }.not_to raise_error
  end

  # @spec POSTGRESQL-PERSISTENCE-028
  it "retains run/type and full prompt-history lookup paths, including unscored metrics" do
    migration.up
    queries = {
      "WHERE agent_run_id = 1 AND metric_type = 'automated'" => "index_quality_metrics_on_agent_run_and_type",
      "WHERE prompt_version_id = 7 ORDER BY created_at DESC" => "index_quality_metrics_on_prompt_version_and_created_at"
    }
    queries.each do |query, index|
      plan = connection.transaction do
        connection.execute("SET LOCAL enable_seqscan = off")
        connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM quality_metrics #{query}")
      end
      expect(plan).to include(index)
    end
    expect(connection.select_values("SELECT agent_run_id FROM quality_metrics WHERE prompt_version_id = 7 ORDER BY created_at DESC")).to eq([ 2, 1 ])
  end

  def indexes
    connection.indexes(:quality_metrics).to_h do |index|
      [ index.name, [ index.columns, index.unique, index.where, index.orders, index.valid? ] ]
    end
  end

  def rows
    connection.select_all("SELECT * FROM quality_metrics ORDER BY id").to_a
  end

  def prepare_table
    connection.create_table(:quality_metrics) do |t|
      %i[agent_run_id prompt_version_id].each { |column| t.bigint column }
      %i[metric_type source].each { |column| t.string column }
      t.decimal :composite_score, precision: 5, scale: 4
      t.jsonb :scores, default: {}
      t.jsonb :metadata, default: {}
      t.timestamp :created_at
    end
    %i[agent_run_id composite_score created_at metric_type prompt_version_id source].each do |column|
      connection.add_index :quality_metrics, column
    end
    connection.add_index :quality_metrics, %i[agent_run_id metric_type], unique: true, name: "index_quality_metrics_on_agent_run_and_type"
    connection.add_index :quality_metrics, %i[prompt_version_id created_at], name: "index_quality_metrics_on_prompt_version_and_created_at"
    connection.add_index :quality_metrics, %i[prompt_version_id created_at],
      name: "idx_quality_metrics_prompt_recent_composite", order: { created_at: :desc }, where: "composite_score IS NOT NULL"
    connection.execute(<<~SQL)
      INSERT INTO quality_metrics (agent_run_id, prompt_version_id, metric_type, source, composite_score, scores, metadata, created_at)
      VALUES (1, 7, 'automated', 'agent_run', 0.8, '{"tests":0.9}', '{"state":"scored"}', '2026-11-27'),
             (2, 7, 'automated', 'agent_run', NULL, '{}', '{"state":"pending"}', '2026-11-28')
    SQL
  end
end
