# frozen_string_literal: true

require "rails_helper"
require "pghero"

RSpec.describe Development::PgHeroOverview::Scan do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "viamin", repo: "paid") }
  let(:client) { instance_double(GithubClient) }
  let(:database) do
    PgHero::Database.new(:primary, "url" => ActiveRecord::Base.connection_db_config.configuration_hash,
      "filter_data" => true)
  end
  let(:now) { Time.utc(2026, 11, 21, 12) }

  def scanner(findings: [], coverage: nil, collector: nil, target_project: project, target_client: client)
    resolved_collector = collector || -> do
      Development::PgHeroOverview::Collect::Result.new(findings: findings, coverage: coverage || complete_coverage)
    end
    described_class.new(project: target_project, client: target_client, environment: "development",
      database: database, collector: resolved_collector,
      dashboard_base_url: "http://localhost:3000", now: -> { now })
  end

  def structural_finding(key: "invalid_index/public/idx_broken")
    Development::PgHeroOverview::Finding.new(
      type: :invalid_index, key: key, title: "Invalid index #{key}",
      observed: { index: key }, observed_at: now, database: "primary",
      persistence_required: false, category: :indexes
    )
  end

  def transient_finding(key: "connection_pressure")
    Development::PgHeroOverview::Finding.new(
      type: :connection_pressure, key: key, title: "Connection pressure",
      observed: { total_connections: 630, threshold: 500 }, observed_at: now,
      database: "primary", persistence_required: true, category: :connections
    )
  end

  def complete_coverage
    {
      long_running: :collected, connections: :collected, maintenance: :collected,
      constraints: :collected, sequences: :collected, indexes: :collected,
      query_stats: :collected, suggested_indexes: :collected, extended: :collected,
      replication: :collected
    }
  end

  before do
    allow(client).to receive(:create_issue) do |repo, title:, body:, labels:|
      Struct.new(:number, :body, :state).new(77, body, "open")
    end
    allow(client).to receive(:update_issue) { |repo, number, **| Struct.new(:number).new(number) }
    allow(client).to receive_messages(all_issues: [], add_comment: nil)
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "does not scan outside development" do
    collector_spy = instance_double(Development::PgHeroOverview::Collect)
    allow(collector_spy).to receive(:call)

    result = described_class.new(project: project, client: client,
      environment: "production", database: database, collector: collector_spy,
      now: -> { now }).call

    expect(result.skipped?).to be(true)
    expect(collector_spy).not_to have_received(:call)
  end

  # @spec RAILS-CONTROL-PLANE-026 RAILS-CONTROL-PLANE-027
  it "serializes GitHub issue filing for a project across scan entry points" do
    scan = scanner(findings: [ structural_finding ])

    expect(project).to receive(:with_lock).and_yield

    expect(scan.call.created).to eq(1)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "files a structural finding immediately and refreshes state on the next scan" do
    scanner = scanner(findings: [ structural_finding ])

    first = scanner.call
    expect(first.created).to eq(1)
    expect(client).to have_received(:create_issue).once
    row = PgHeroOverviewFinding.find_by!(finding_key: "invalid_index/public/idx_broken")
    expect(row.consecutive_observations).to eq(1)
    expect(row.github_issue_number).to eq(77)

    allow(client).to receive(:all_issues) { [ Struct.new(:number, :body, :state).new(77, "stale body", "open") ] }
    second = scanner.call
    expect(second.created).to eq(0)
    expect(second.updated).to eq(1)
    row.reload
    expect(row.consecutive_observations).to eq(2)
    expect(row.last_seen_at.to_i).to eq(now.to_i)
  end

  # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-028
  it "keeps finding state and issue lifecycles isolated to each self repository" do
    other_project = create(:project, account: create(:account), owner: "other", repo: "paid")
    other_client = instance_double(GithubClient)
    allow(other_client).to receive(:create_issue) do |repo, title:, body:, labels:|
      Struct.new(:number, :body, :state).new(88, body, "open")
    end
    allow(other_client).to receive(:update_issue) { |repo, number, **| Struct.new(:number).new(number) }
    allow(other_client).to receive_messages(all_issues: [], add_comment: nil)

    scanner(findings: [ structural_finding ]).call
    scanner(findings: [ structural_finding ], target_project: other_project, target_client: other_client).call

    expect(PgHeroOverviewFinding.where(finding_key: "invalid_index/public/idx_broken").pluck(:project_id, :github_issue_number))
      .to contain_exactly([ project.id, 77 ], [ other_project.id, 88 ])

    scanner(findings: []).call

    expect(client).to have_received(:update_issue).with("viamin/paid", 77, state: "closed")
    expect(other_client).not_to have_received(:update_issue)
    expect(PgHeroOverviewFinding.find_by!(project: other_project, finding_key: "invalid_index/public/idx_broken").resolved_at).to be_nil
  end

  # @spec RAILS-CONTROL-PLANE-028
  it "does not file a transient finding until it persists across consecutive scans" do
    first = scanner(findings: [ transient_finding ]).call
    expect(first.created).to eq(0)
    expect(client).not_to have_received(:create_issue)
    expect(PgHeroOverviewFinding.find_by!(finding_key: "connection_pressure").consecutive_observations).to eq(1)

    second = scanner(findings: [ transient_finding ]).call
    expect(second.created).to eq(1)
  end

  # @spec RAILS-CONTROL-PLANE-028
  it "resets persistence when a transient finding stops being observed between scans" do
    scanner(findings: [ transient_finding ]).call

    scanner(findings: []).call
    expect(PgHeroOverviewFinding.find_by!(finding_key: "connection_pressure").consecutive_observations).to eq(0)

    third = scanner(findings: [ transient_finding ]).call
    expect(third.created).to eq(0)
  end

  # @spec RAILS-CONTROL-PLANE-028
  it "resets persistence counters after a long observation gap" do
    scan = scanner(findings: [ transient_finding ])
    scan.call

    travel_to(Time.current + PgHeroOverviewFinding::STALE_AFTER + 1.day) do
      expect(scan.call.created).to eq(0)
    end
  end

  # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-029
  it "closes the issue when a collected category no longer shows the finding and reopens on recurrence" do
    scanner(findings: [ structural_finding ]).call
    row = PgHeroOverviewFinding.find_by!(finding_key: "invalid_index/public/idx_broken")
    allow(client).to receive(:all_issues) { [ Struct.new(:number, :body, :state).new(77, "body", "open") ] }

    closed = scanner(findings: []).call
    expect(closed.closed).to eq(1)
    expect(client).to have_received(:update_issue).with("viamin/paid", 77, state: "closed")
    expect(row.reload.resolved_at).to be_present

    recurred = scanner(findings: [ structural_finding ]).call
    expect(recurred.reopened).to eq(1)
    expect(client).to have_received(:update_issue).with(
      "viamin/paid", 77, state: "open", body: a_string_including("**Finding type:** invalid_index")
    )
    expect(row.reload.resolved_at).to be_nil
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "keeps an issue open when its category could not be observed this scan" do
    scanner(findings: [ structural_finding ]).call

    result = scanner(findings: [], coverage: complete_coverage.merge(indexes: :timeout)).call

    expect(result.closed).to eq(0)
    expect(client).not_to have_received(:update_issue)
    expect(result).not_to be_complete
    expect(result.incomplete_categories).to include(:indexes)
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "reports an incomplete scan with a query-stats coverage finding" do
    coverage_finding = Development::PgHeroOverview::Finding.new(
      type: :query_stats_unavailable, key: "query_stats_unavailable", title: "Query stats unavailable",
      observed: { reason: "extension missing" }, observed_at: now, database: "primary",
      persistence_required: false, category: :query_stats
    )

    result = scanner(findings: [ coverage_finding ],
      coverage: complete_coverage.merge(query_stats: :unavailable, suggested_indexes: :unavailable)).call

    expect(result.created).to eq(1)
    expect(result).not_to be_complete
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "propagates collector database errors instead of reporting a clean scan" do
    failing = -> { raise ActiveRecord::ConnectionNotEstablished, "recovering" }

    expect { scanner(collector: failing).call }.to raise_error(ActiveRecord::ConnectionNotEstablished)
  end

  # @spec RAILS-CONTROL-PLANE-028
  it "retries cap-deferred findings on the next scan" do
    findings = (1..6).map { |i| structural_finding(key: "invalid_index/public/idx_#{i}") }
    scan = scanner(findings: findings)

    first = scan.call
    expect(first.created).to eq(Development::PgHeroOverview::Policy::MAX_NEW_ISSUES_PER_RUN)
    expect(first.deferred_keys).to contain_exactly("invalid_index/public/idx_6")

    second = scan.call
    expect(second.created).to eq(1)
    expect(second.deferred_keys).to be_empty
  end
end
