# frozen_string_literal: true

require "rails_helper"
require "pghero"

RSpec.describe Development::PgHeroOverview::Scan do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "viamin", repo: "paid", allowed_github_usernames: [ "viamin" ]) }
  let(:client) { instance_double(GithubClient) }
  let(:database) do
    PgHero::Database.new(:primary, "url" => ActiveRecord::Base.connection_db_config.configuration_hash,
      "filter_data" => true)
  end
  let(:remote) { [] }
  let(:now) { Time.utc(2026, 11, 21, 12) }

  def scanner(findings: [], coverage: nil, collector: nil, target_project: project, target_client: client, dry_run: false)
    resolved_collector = collector || -> do
      Development::PgHeroOverview::Collect::Result.new(findings: findings, coverage: coverage || complete_coverage)
    end
    described_class.new(project: target_project, client: target_client, environment: "development",
      database: database, collector: resolved_collector, dry_run: dry_run,
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

  def github_issue(number, body, state)
    Struct.new(:number, :body, :state, :title, :user).new(number, body, state, "PgHero repair", Struct.new(:login).new("viamin"))
  end

  before do
    # These lifecycle cases receive independent repairs from the external assessor.
    allow(Llm::Request).to receive(:call) do |prompt:, **|
      input = JSON.parse(prompt.split("BEGIN UNTRUSTED JSON EVIDENCE\n", 2).last
        .split("\nEND UNTRUSTED JSON EVIDENCE", 2).first)
      assessment = { "repairs" => input.fetch("findings").map do |finding|
        { "title" => finding.fetch("title"), "instructions" => "Investigate and verify this repair",
          "rationale" => "Independent repair", "evidence" => "Catalog evidence",
          "publication_ready" => true, "missing_evidence" => [],
          "finding_keys" => [ finding.fetch("identity") ], "owner_issue_number" => nil, "owner_pr_number" => nil }
      end, "deferred" => [] }
      Struct.new(:output).new(JSON.generate(assessment))
    end
    allow(client).to receive(:create_issue) do |repo, title:, body:, labels:|
      github_issue(77, body, "open").tap { |issue| remote << issue }
    end
    allow(client).to receive(:update_issue) do |repo, number, **attributes|
      issue = remote.find { |record| record.number == number }
      attributes.each { |key, value| issue.public_send("#{key}=", value) } if issue
      issue
    end
    allow(client).to receive(:all_issues) { remote }
    allow(client).to receive(:add_comment)
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

    allow(client).to receive(:all_issues) { [ github_issue(77, "stale body", "open") ] }
    second = scanner.call
    expect(second.created).to eq(0)
    expect(second.updated).to eq(1)
    row.reload
    expect(row.consecutive_observations).to eq(2)
    expect(row.last_seen_at.to_i).to eq(now.to_i)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "recovers the first remote issue when a later publication rolls back local observation state" do
    first = structural_finding
    second = structural_finding(key: "invalid_index/public/idx_other")
    fail_next_create = true
    allow(client).to receive(:create_issue) do |_, body:, **|
      if remote.any? && fail_next_create
        fail_next_create = false
        raise GithubClient::Error, "later write failed"
      end
      github_issue(77 + remote.size, body, "open").tap { |issue| remote << issue }
    end
    scan = scanner(findings: [ first, second ])

    expect { Project.transaction(requires_new: true) { scan.call } }.to raise_error(GithubClient::Error, "later write failed")
    expect(PgHeroOverviewFinding.where(project: project)).to be_empty
    expect(remote.size).to eq(1)
    expect(scan.call.created).to eq(1)
    expect(remote.size).to eq(2)
    expect(PgHeroOverviewFinding.where(project: project).pluck(:finding_key, :github_issue_number))
      .to contain_exactly([ first.key, 77 ], [ second.key, 78 ])
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
    allow(client).to receive(:all_issues) { [ github_issue(77, "body", "open") ] }

    closed = scanner(findings: []).call
    expect(closed.closed).to eq(1)
    expect(client).to have_received(:update_issue).with("viamin/paid", 77, state: "closed")
    expect(row.reload.resolved_at).to be_present

    allow(client).to receive(:all_issues) { [ github_issue(77, "body", "closed") ] }
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

  # @spec RAILS-CONTROL-PLANE-035
  it "previews the same assessment without GitHub writes or committed scanner state" do
    result = nil
    expect {
      result = scanner(findings: [ structural_finding ], dry_run: true).call
    }.not_to change(PgHeroOverviewFinding, :count)

    expect(PgHeroOverviewRepair.count).to eq(0)
    expect(result.dry_run).to be(true)
    expect(result.created).to eq(1)
    expect(result.repair_plans.first.fetch("action")).to eq("create")
    expect(client).not_to have_received(:create_issue)
    expect(client).not_to have_received(:update_issue)
    expect(client).not_to have_received(:add_comment)
  end

  # @spec RAILS-CONTROL-PLANE-036
  it "does not advance persisted assessment history during a preview" do
    finding = structural_finding
    row = PgHeroOverviewFinding.create!(project: project, database: finding.database, finding_key: finding.key,
      finding_type: finding.type, first_seen_at: now, last_seen_at: now, consecutive_observations: 1,
      assessment: { "assessed_at" => 1.day.ago.utc.iso8601, "reason" => "Previous evidence" })
    previous = row.assessment

    result = scanner(findings: [ finding ], dry_run: true).call

    expect(result.assessed_keys).to eq([ finding.identity ])
    expect(row.reload.assessment).to eq(previous)
    expect(client).not_to have_received(:create_issue)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "recovers a remote issue when publication succeeded before the local transaction failed" do
    allow(client).to receive(:create_issue) do |_, body:, **|
      remote << github_issue(77, body, "open")
      raise GithubClient::Error, "Response lost after remote publication"
    end
    scan = scanner(findings: [ structural_finding ])

    expect { scan.call }.to raise_error(GithubClient::Error)
    expect(PgHeroOverviewFinding.count).to eq(0)
    expect(PgHeroOverviewRepair.count).to eq(0)

    result = scan.call

    expect(result.created).to eq(0)
    expect(client).to have_received(:create_issue).once
    expect(PgHeroOverviewRepair.sole.github_issue_number).to eq(77)
    expect(PgHeroOverviewFinding.sole.github_issue_number).to eq(77)
  end
end
