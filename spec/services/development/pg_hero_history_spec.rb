# frozen_string_literal: true

require "rails_helper"
require "pghero"

RSpec.describe "Development::PgHeroHistory" do
  around do |example|
    original_environment = PgHero.env
    PgHero.env = "development"
    reset_pghero_config
    example.run
  ensure
    PgHero.env = original_environment
    reset_pghero_config
  end

  let(:database) do
    PgHero::Database.new(:primary, "url" => ActiveRecord::Base.connection_db_config.configuration_hash,
      "filter_data" => true)
  end
  let(:history) { Development::PgHeroHistory.new(environment: "development", database: database) }

  # @spec RAILS-CONTROL-PLANE-020
  it "persists interval totals and normalizes literal SQL before storage" do
    allow(database).to receive_messages(query_stats: [
      { query: "SELECT 'private-investigation-value'", query_hash: 123, user: "paid", calls: 7, total_time: 325.0 }
    ], reset_query_stats: true)

    history.capture_queries

    sample = PgHero::QueryStats.find_by!(query_hash: 123)
    expect(sample.attributes).to include("database" => "primary", "calls" => 7, "total_time" => 325.0)
    expect(sample.captured_at).to be_present
    expect(PgHero::Query.find(sample.query_id).query).to eq("SELECT $1")
  end

  # @spec RAILS-CONTROL-PLANE-020
  it "does not store literal utility-statement values" do
    allow(database).to receive_messages(query_stats: [
      { query: "SET application_name = 'private-worker-name'", query_hash: 456, user: "paid", calls: 1, total_time: 1.0 }
    ], reset_query_stats: true)

    history.capture_queries

    expect(PgHero::Query.pluck(:query).join).not_to include("private-worker-name")
  end

  # @spec RAILS-CONTROL-PLANE-020
  it "removes comments and filters utility statements whose values PostgreSQL does not normalize" do
    allow(database).to receive_messages(query_stats: [
      { query: "SELECT 1 /* private-comment-token */", query_hash: 501, user: "paid", calls: 1, total_time: 1.0 },
      { query: "COMMENT ON TABLE issues IS 'private-utility-value'", query_hash: 502, user: "paid", calls: 1, total_time: 1.0 },
      { query: "DO $$ BEGIN RAISE NOTICE 'private-body-value'; END $$", query_hash: 503, user: "paid", calls: 1, total_time: 1.0 }
    ], reset_query_stats: true)

    history.capture_queries

    queries = PgHero::Query.pluck(:query)
    expect(queries).to include("SELECT $1")
    expect(queries.join).not_to include("private-comment-token", "private-utility-value", "private-body-value")
    expect(PgHero::QueryStats.count).to eq(3)
  end

  # @spec RAILS-CONTROL-PLANE-020
  it "does not collect outside development" do
    expect(database).not_to receive(:capture_query_stats)

    Development::PgHeroHistory.new(environment: "production", database: database).capture_queries
  end

  # @spec RAILS-CONTROL-PLANE-022
  it "propagates a recovery failure without inserting a successful sample" do
    allow(database).to receive(:query_stats).and_raise(ActiveRecord::ConnectionNotEstablished, "database is recovering")

    expect { history.capture_queries }.to raise_error(ActiveRecord::ConnectionNotEstablished, "database is recovering")
    expect(PgHero::QueryStats.count).to eq(0)
  end

  # @spec RAILS-CONTROL-PLANE-022
  it "reports reset permission failure instead of silently dropping an interval" do
    allow(database).to receive(:query_stats).and_return([
      { query: "SELECT $1", query_hash: 123, user: "paid", calls: 1, total_time: 1.0 }
    ])
    allow(database).to receive(:reset_query_stats).and_raise(ActiveRecord::StatementInvalid, "permission denied")

    expect { history.capture_queries }.to raise_error(ActiveRecord::StatementInvalid, "permission denied")
    expect(PgHero::QueryStats.count).to eq(0)
  end

  # @spec RAILS-CONTROL-PLANE-021
  it "records actual database relation sizes" do
    history.capture_space

    sample = PgHero::SpaceStats.find_by!(database: "primary", relation: "issues")
    expect(sample.size).to be_positive
    expect(sample.captured_at).to be_present
  end

  # @spec RAILS-CONTROL-PLANE-021
  it "prunes old samples and unused SQL while keeping retained history" do
    old_query = PgHero::Query.create!(query: "SELECT $1 AS old_sample")
    shared_query = PgHero::Query.create!(query: "SELECT $1 AS shared_sample")
    old_time = 15.days.ago
    recent_time = 1.day.ago
    [ [ old_query, old_time ], [ shared_query, old_time ], [ shared_query, recent_time ] ].each do |query, captured_at|
      PgHero::QueryStats.create!(database: "primary", query_id: query.id, query_hash: query.id,
        user: "paid", calls: 1, total_time: 1.0, captured_at: captured_at)
    end
    [ old_time, recent_time ].each do |captured_at|
      PgHero::SpaceStats.create!(database: "primary", schema: "public", relation: "issues", size: 8192, captured_at: captured_at)
    end
    issue_count = Issue.count

    history.clean_history

    expect(PgHero::QueryStats.pluck(:query_id)).to eq([ shared_query.id ])
    expect(PgHero::Query.pluck(:id)).to eq([ shared_query.id ])
    expect(PgHero::SpaceStats.count).to eq(1)
    expect(Issue.count).to eq(issue_count)
  end

  # @spec RAILS-CONTROL-PLANE-020
  it "skips capture and cleanup while another connection holds their shared lock" do
    lock_key = Development::PgHeroHistory::LOCK_KEY
    lock_connection = PG.connect(ActiveRecord::Base.connection_db_config.configuration_hash.slice(:host, :port, :password)
      .merge(dbname: ActiveRecord::Base.connection_db_config.database,
        user: ActiveRecord::Base.connection_db_config.configuration_hash[:username]))
    lock_connection.exec_params("SELECT pg_advisory_lock($1)", [ lock_key ])
    expect(database).not_to receive(:capture_query_stats)
    expect(database).not_to receive(:capture_space_stats)
    expect(database).not_to receive(:clean_query_stats)

    history.capture_queries
    history.capture_space
    history.clean_history
  ensure
    lock_connection&.close
  end

  def reset_pghero_config
    %i[config databases file_config stats_database_url].each do |name|
      PgHero.remove_instance_variable(:"@#{name}") if PgHero.instance_variable_defined?(:"@#{name}")
    end
  end
end
