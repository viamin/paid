# frozen_string_literal: true

require "rails_helper"
require "pghero"
require "pg_query"

RSpec.describe Development::PgHeroOverview::Collect do
  around do |example|
    original_environment = PgHero.env
    PgHero.env = "development"
    reset_pghero_config
    example.run
  ensure
    PgHero.env = original_environment
    reset_pghero_config
  end

  # Constructed through the YAML config (like development) so configured
  # thresholds such as slow_query_ms apply; every read below is stubbed.
  let(:database) do
    reset_pghero_config
    PgHero.databases.fetch(:primary)
  end
  let(:frozen_now) { Time.utc(2026, 11, 21, 12) }
  let(:collect) { described_class.new(environment: "development", database: database, now: -> { frozen_now }) }

  def stub_overview_clean
    allow(database).to receive_messages(
      replica?: false,
      long_running_queries: [],
      connection_states: { "idle" => 3, "active" => 2 },
      total_connections_threshold: 500,
      transaction_id_danger: [],
      sequences: [],
      sequence_danger: [],
      indexes: [],
      invalid_indexes: [],
      duplicate_indexes: [],
      invalid_constraints: [],
      query_stats_enabled?: true,
      query_stats: [],
      slow_queries: [],
      suggested_indexes_by_query: {},
      suggested_indexes: [],
      replication_slots: [],
      index_hit_rate: 0.995,
      table_hit_rate: 0.997,
      cache_hit_rate_threshold: 98,
      unused_indexes: [],
      unused_index_bytes: 10.megabytes
    )
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "collects a clean, complete scan with no findings" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])

    result = collect.call

    expect(result.findings).to be_empty
    expect(result).to be_complete
    expect(result.coverage).to eq(
      long_running: :collected, connections: :collected, maintenance: :collected,
      constraints: :collected, sequences: :collected, indexes: :collected,
      query_stats: :collected, suggested_indexes: :collected, extended: :collected,
      replication: :collected
    )
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "does not collect outside development" do
    expect(database).not_to receive(:long_running_queries)

    result = described_class.new(environment: "production", database: database).call

    expect(result).to be_skipped
    expect(result.findings).to be_empty
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "normalizes slow queries into findings keyed by query hash with windowed evidence" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])
    allow(database).to receive_messages(slow_queries: [
      { query: "SELECT * FROM issues WHERE token = 'secret-token-value'", query_hash: 123_456,
        calls: 12, average_time: 245.3, total_time: 2943.6 }
    ])

    finding = collect.call.findings.sole

    expect(finding.type).to eq(:slow_query)
    expect(finding.key).to eq("slow_query/123456")
    expect(finding.observed[:average_ms]).to eq(245.3)
    expect(finding.observed[:calls]).to eq(12)
    expect(finding.observed[:threshold_ms]).to eq(100)
    expect(finding.observed[:threshold_calls]).to eq(5)
    expect(finding.observed[:query]).not_to include("secret-token-value")
    expect(finding.observed_at).to eq(Time.utc(2026, 11, 21, 12))
  end

  # @spec RAILS-CONTROL-PLANE-038
  it "retains sanitized slow-query predicates and ordering beyond the display excerpt" do
    stub_overview_clean
    columns = (1..120).map { |number| "issues.column_#{number}" }.join(", ")
    sql = "SELECT #{columns} FROM issues WHERE token = 'private-token' ORDER BY issues.id"
    allow(database).to receive(:slow_queries).and_return([
      { query: sql, query_hash: 123_456, calls: 12, average_time: 245.3 }
    ])

    finding = collect.call.findings.sole

    expect(finding.key).to eq("slow_query/123456")
    expect(finding.observed[:query]).to eq(Development::PgHeroQueryText.call(sql))
    expect(finding.observed[:query]).to include("WHERE", "ORDER BY")
    expect(finding.observed[:query]).not_to include("private-token")
    expect(finding.observed[:query_truncated]).to be false
  end

  # @spec RAILS-CONTROL-PLANE-038
  it "marks oversized sanitized slow SQL as truncated within its byte budget" do
    stub_overview_clean
    columns = (1..1_000).map { |number| %Q(issues."café_column_#{number}") }.join(", ")
    sql = "SELECT #{columns} FROM issues WHERE token = 'private-token'"
    allow(database).to receive(:slow_queries).and_return([
      { query: sql, query_hash: 123_456, calls: 12, average_time: 245.3 }
    ])

    finding = collect.call.findings.sole

    expect(finding.key).to eq("slow_query/123456")
    expect(finding.observed[:query].bytesize).to be <= 16_000
    expect(finding.observed[:query].valid_encoding?).to be true
    expect(finding.observed[:query]).not_to include("private-token")
    expect(finding.observed[:query_truncated]).to be true
  end

  # @spec RAILS-CONTROL-PLANE-038
  it "preserves the existing long-running query excerpt and identity" do
    stub_overview_clean
    columns = (1..120).map { |number| "issues.column_#{number}" }.join(", ")
    sql = "SELECT #{columns} FROM issues WHERE token = 'private-token'"
    allow(database).to receive(:long_running_queries).and_return([
      { duration_ms: 90_000, state: "active", backend_type: "client backend", query: sql }
    ])
    excerpt = Development::PgHeroQueryText.call(sql).truncate(1_000)

    finding = collect.call.findings.sole

    expect(finding.observed[:query]).to eq(excerpt)
    expect(finding.key).to eq("long_running_query/#{Digest::SHA256.hexdigest(excerpt)}")
  end

  # @spec RAILS-CONTROL-PLANE-025 RAILS-CONTROL-PLANE-027
  it "redacts literals from long-running query text and excludes autovacuum workers" do
    stub_overview_clean
    allow(database).to receive_messages(long_running_queries: [
      { pid: 101, duration: 90.seconds, state: "active", backend_type: "client backend",
        query: "SELECT * FROM runners WHERE api_key = 'ak_live_secret'" },
      { pid: 102, duration: 300.seconds, state: "active", backend_type: "autovacuum worker",
        query: "autovacuum: VACUUM ANALYZE public.issues" }
    ])

    findings = collect.call.findings

    expect(findings.size).to eq(1)
    expect(findings.first.type).to eq(:long_running_query)
    expect(findings.first.observed[:query]).not_to include("ak_live_secret")
    expect(findings.first.persistence_required).to be(true)
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "collects index findings with stable relation identities" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])
    allow(database).to receive_messages(
      invalid_indexes: [ { schema: "public", table: "issues", name: "idx_broken", index: "idx_broken", valid: false } ],
      duplicate_indexes: [
        { unneeded_index: { schema: "public", table: "issues", name: "index_issues_on_a" },
          covering_index: { schema: "public", table: "issues", name: "index_issues_on_a_b" } }
      ],
      unused_indexes: [ { schema: "public", table: "issues", index: "idx_unused", size_bytes: 20.megabytes, index_scans: 0 } ]
    )

    keys = collect.call.findings.map(&:key)

    expect(keys).to contain_exactly(
      "invalid_index/public/idx_broken",
      "duplicate_index/public/index_issues_on_a",
      "unused_index/public/idx_unused"
    )
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "collects sequence, transaction-id, constraint, replication-slot, and unreadable-sequence findings" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])
    allow(database).to receive_messages(
      sequence_danger: [ { schema: "public", sequence: "issues_id_seq", table: "issues", column: "id", last_value: 95, max_value: 100 } ],
      sequences: [
        { schema: "public", sequence: "hidden_seq", table: "locked", column: "ref", readable: false }
      ],
      transaction_id_danger: [ { schema: "public", table: "agent_runs", transactions_left: 1_000 } ],
      invalid_constraints: [ { schema: "public", table: "runners", name: "fk_rails_abc" } ],
      replication_slots: [ { slot_name: "stale_slot", database: "primary", active: false } ]
    )

    keys = collect.call.findings.map(&:key)

    expect(keys).to contain_exactly(
      "sequence_danger/issues/id",
      "unreadable_sequence/locked/ref",
      "xid_danger/public/agent_runs",
      "invalid_constraint/public/fk_rails_abc",
      "replication_slot/stale_slot"
    )
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "collects connection pressure, idle transactions, and cache rates only past their thresholds" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])
    allow(database).to receive_messages(
      connection_states: { "idle" => 480, "active" => 30, "idle in transaction" => 120 },
      index_hit_rate: 0.97,
      table_hit_rate: 0.93
    )

    findings = collect.call.findings

    expect(findings.map(&:type)).to contain_exactly(:connection_pressure, :idle_in_transaction,
      :cache_hit_rate, :cache_hit_rate)
    expect(findings.find { |f| f.type == :connection_pressure }.observed).to include(total_connections: 630, threshold: 500)
    expect(findings.find { |f| f.type == :idle_in_transaction }.observed).to include(idle_in_transaction: 120, threshold: 100)
    expect(findings.find { |f| f.key == "cache_hit_rate/table" }.observed).to include(table_rate_pct: 93.0, threshold_pct: 98)
    expect(findings).to all(have_attributes(persistence_required: true))
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "skips nil cache rates and sub-threshold connection counts" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])
    allow(database).to receive_messages(index_hit_rate: nil, table_hit_rate: nil)

    expect(collect.call.findings).to be_empty
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "collects suggested indexes with the Overview's minimum impact thresholds" do
    stub_overview_clean
    allow(database).to receive(:query_stats) do |**options|
      expect(options).to include(historical: true, start_at: frozen_now - 3.hours)
      []
    end
    allow(database).to receive(:suggested_indexes_by_query) do |**options|
      stats = options.fetch(:query_stats)
      expect(stats).to all(satisfy { |q| q[:average_time] >= 20 && q[:calls] >= 50 })
      {}
    end
    allow(database).to receive_messages(suggested_indexes: [
      { table: "issues", columns: [ "project_id", "state" ], queries: [ "SELECT * FROM issues WHERE project_id = $1 AND state = $2" ] }
    ])

    finding = collect.call.findings.sole

    expect(finding.type).to eq(:suggested_index)
    expect(finding.key).to eq("suggested_index/issues/project_id,state")
    expect(finding.observed[:queries].first).to be_present
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "reports unavailable query stats as a coverage finding and an incomplete scan" do
    stub_overview_clean
    allow(database).to receive_messages(query_stats_enabled?: false)

    result = collect.call

    finding = result.findings.sole
    expect(finding.type).to eq(:query_stats_unavailable)
    expect(result).not_to be_complete
    expect(result.incomplete_categories).to contain_exactly(:query_stats, :suggested_indexes)
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "marks the scan incomplete when sequence or index collection times out without closing those categories" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])
    allow(database).to receive(:sequences).and_raise(ActiveRecord::LockWaitTimeout.new("lock timeout"))

    result = collect.call

    expect(result).not_to be_complete
    expect(result.incomplete_categories).to contain_exactly(:sequences)
    types = result.findings.map(&:type)
    expect(types).not_to include(:sequence_danger, :unreadable_sequence)
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "marks index-dependent categories incomplete when the index catalog read times out" do
    stub_overview_clean
    allow(database).to receive(:query_stats).and_return([])
    allow(database).to receive(:indexes).and_raise(ActiveRecord::QueryCanceled, "canceling statement due to statement timeout")

    result = collect.call

    expect(result).not_to be_complete
    expect(result.incomplete_categories).to contain_exactly(:indexes, :suggested_indexes)
    types = result.findings.map(&:type)
    expect(types).not_to include(:invalid_index, :duplicate_index, :suggested_index)
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "propagates collector database errors" do
    stub_overview_clean
    allow(database).to receive(:long_running_queries).and_raise(ActiveRecord::ConnectionNotEstablished, "recovering")

    expect { collect.call }.to raise_error(ActiveRecord::ConnectionNotEstablished)
  end

  def reset_pghero_config
    %i[config databases file_config].each do |name|
      PgHero.remove_instance_variable(:"@#{name}") if PgHero.instance_variable_defined?(:"@#{name}")
    end
  end
  # @spec RAILS-CONTROL-PLANE-037
  it "supplies actual catalog evidence for duplicate-index repair assessment" do
    stub_overview_clean
    unneeded = { schema: "public", table: "issues", name: "issues_project",
      definition: "CREATE INDEX issues_project ON issues USING btree (project_id)", valid: true, unique: false }
    covering = { schema: "public", table: "issues", name: "issues_project_status",
      definition: "CREATE INDEX issues_project_status ON issues USING btree (project_id, status)", valid: true, unique: false }
    allow(database).to receive(:duplicate_indexes).and_return([ { unneeded_index: unneeded, covering_index: covering } ])

    finding = collect.call.findings.find { |entry| entry.type == :duplicate_index }

    expect(finding.observed).to include(unneeded_definition: unneeded[:definition],
      covering_definition: covering[:definition], unneeded_valid: true, covering_valid: true,
      unneeded_unique: false, covering_unique: false)
  end

  context "with alternate catalog indexes" do
    let(:unneeded) do
      { schema: "public", table: "issues", name: "issues_project",
        definition: "CREATE INDEX issues_project ON issues (project_id)", valid: true, unique: false }
    end
    let(:chosen) { unneeded.merge(name: "issues_project_status", definition: "CREATE INDEX issues_project_status ON issues (project_id, status)") }
    let(:alternate) { unneeded.merge(name: "issues_project_kind", definition: "CREATE UNIQUE INDEX issues_project_kind ON issues (project_id, kind)", unique: true) }
    let(:partial) { alternate.merge(name: "issues_active", definition: "CREATE UNIQUE INDEX issues_active ON issues (project_id, kind) WHERE active") }
    let(:invalid) { alternate.merge(name: "issues_invalid", definition: "CREATE UNIQUE INDEX issues_invalid ON issues (project_id, kind)", valid: false) }
    let(:catalog) { [ unneeded, chosen, alternate, partial, invalid ] }

    before do
      stub_overview_clean
      allow(database).to receive_messages(
        indexes: catalog + [ alternate.merge(schema: "other"), alternate.merge(table: "other") ],
        duplicate_indexes: [ { unneeded_index: unneeded, covering_index: chosen } ])
    end

    # @spec RAILS-CONTROL-PLANE-040
    it "retains all same-table alternatives without endorsing partial or invalid indexes" do
      evidence = collect.call.findings.find { |entry| entry.type == :duplicate_index }.observed

      expect(evidence.fetch(:table_indexes)).to match_array(catalog.map { |index| index.slice(:name, :definition, :valid, :unique) })
      expect(evidence.fetch(:covering_index)).to eq(chosen.fetch(:name))
      expect(database).to have_received(:indexes).once
    end

    # @spec RAILS-CONTROL-PLANE-040
    it "keeps identity and fingerprint stable when catalog rows arrive in another order" do
      first = collect.call.findings.find { |entry| entry.type == :duplicate_index }
      allow(database).to receive(:indexes).and_return(catalog.reverse)
      second = collect.call.findings.find { |entry| entry.type == :duplicate_index }

      expect(second.identity).to eq("primary/duplicate_index/public/issues_project")
      expect(second.fingerprint).to eq(first.fingerprint)
    end
  end
end
