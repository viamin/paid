# frozen_string_literal: true

require "rails_helper"

RSpec.describe Development::PgHeroOverview::IssueFiler do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "viamin", repo: "paid") }
  let(:client) { instance_double(GithubClient) }
  let(:filer) do
    described_class.new(project: project, client: client,
      dashboard_base_url: "http://localhost:3000", now: -> { Time.utc(2026, 11, 21, 12) })
  end
  let(:expected_labels) do
    [ Development::PgHeroOverview::IssueFiler::LABEL, project.generated_label_name, project.automation_label_name ].uniq
  end
  let(:created_bodies) { [] }

  def finding(type: :invalid_index, key: "invalid_index/public/idx_broken", observed: { table: "public.issues" }, category: :indexes, persistence_required: false)
    Development::PgHeroOverview::Finding.new(
      type: type, key: key, title: "Finding #{key}",
      observed: observed, observed_at: Time.utc(2026, 11, 21, 12),
      database: "primary", persistence_required: persistence_required, category: category
    )
  end

  def row_for(finding, **attributes)
    PgHeroOverviewFinding.create!(
      project: project, database: finding.database, finding_key: finding.key, finding_type: finding.type.to_s,
      first_seen_at: 2.days.ago, last_seen_at: 1.hour.ago, consecutive_observations: 3, **attributes
    )
  end

  def github_issue(number:, body: "", state: "open")
    Struct.new(:number, :body, :state).new(number, body, state)
  end

  before do
    allow(client).to receive(:create_issue) do |repo, title:, body:, labels:|
      created_bodies << body
      github_issue(number: 50 + created_bodies.size, body: body)
    end
    allow(client).to receive(:update_issue) { |repo, number, **| github_issue(number: number) }
    allow(client).to receive_messages(all_issues: [], add_comment: nil)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "creates one labeled issue per finding in the self repo" do
    structural = finding(observed: { table: "public.issues", index: "idx_broken", valid: "f" })
    slow = finding(type: :slow_query, key: "slow_query/991", category: :query_stats,
      observed: { query: "SELECT * FROM issues WHERE token = $1", average_ms: 245.3, calls: 12,
                  threshold_ms: 100, threshold_calls: 5 })

    filer.sync(observed_findings: [ structural, slow ], actionable_findings: [ structural, slow ],
      rows: {}, collected_categories: Set.new(%i[indexes query_stats]))

    expect(client).to have_received(:create_issue).twice do |repo, title:, body:, labels:|
      expect(repo).to eq("viamin/paid")
      expect(labels).to eq(expected_labels)
    end
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "includes full evidence, thresholds, timestamps, dashboard link, and investigation prompt" do
    slow = finding(type: :slow_query, key: "slow_query/991", category: :query_stats,
      observed: { query: "SELECT * FROM issues WHERE token = $1", average_ms: 245.3, calls: 12,
                  threshold_ms: 100, threshold_calls: 5 })

    filer.sync(observed_findings: [ slow ], actionable_findings: [ slow ],
      rows: {}, collected_categories: Set.new(%i[query_stats]))

    slow_body = created_bodies.first
    expect(slow_body).to include("pghero-overview-finding: primary/slow_query/991")
    expect(slow_body).to include("**Finding type:** slow_query")
    expect(slow_body).to include("average_ms: 245.3 (threshold: 100)")
    expect(slow_body).to include("calls: 12 (threshold: 5)")
    expect(slow_body).to include("**Observed at:** 2026-11-21T12:00:00Z")
    expect(slow_body).to include("**Database:** primary")
    expect(slow_body).to include("http://localhost:3000/pghero?database=primary")
    expect(slow_body).to include("investigation lead")
    expect(slow_body).not_to include("CREATE INDEX")
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "links the created issue number back to the finding state row" do
    f = finding

    filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: {}, collected_categories: Set.new(%i[indexes]))

    row = PgHeroOverviewFinding.find_by!(project: project, database: "primary", finding_key: f.key)
    expect(row.github_issue_number).to eq(51)
    expect(row.resolved_at).to be_nil
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "updates an existing tracked issue only when the evidence changed" do
    f = finding
    row = row_for(f, github_issue_number: 7)
    allow(client).to receive(:all_issues) { [ github_issue(number: 7, body: filer.send(:body_for, f)) ] }

    filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: { f.key => row },
      collected_categories: Set.new(%i[indexes]))
    expect(client).not_to have_received(:update_issue)

    changed = finding(observed: { table: "public.issues", index: "idx_broken", valid: "f", detail: "new evidence" })
    filer.sync(observed_findings: [ changed ], actionable_findings: [ changed ],
      rows: { changed.key => row }, collected_categories: Set.new(%i[indexes]))

    expect(client).to have_received(:update_issue).once do |repo, number, **options|
      expect(repo).to eq("viamin/paid")
      expect(number).to eq(7)
      expect(options[:body]).to include("pghero-overview-finding: primary/#{changed.key}")
    end
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "reopens a tracked issue that GitHub reports closed when the finding persists" do
    f = finding
    row = row_for(f, github_issue_number: 7)

    changed = finding(observed: { table: "public.issues", index: "idx_broken", valid: "f", detail: "new evidence" })

    result = filer.sync(observed_findings: [ changed ], actionable_findings: [ changed ], rows: { changed.key => row },
      collected_categories: Set.new(%i[indexes]))

    expect(client).to have_received(:update_issue).with("viamin/paid", 7,
      state: "open", body: include("detail: new evidence"))
    expect(client).to have_received(:add_comment).with("viamin/paid", 7, kind_of(String))
    expect(result.reopened).to eq(1)
  end

  # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-029
  it "closes a tracked issue whose finding disappeared and records the last observation" do
    f = finding
    row = row_for(f, github_issue_number: 7)
    row.update!(last_seen_at: Time.utc(2026, 11, 20, 12))
    allow(client).to receive(:all_issues) { [ github_issue(number: 7, body: filer.send(:body_for, f)) ] }
    comments = []
    allow(client).to receive(:add_comment) { |_, _, body| comments << body }

    result = filer.sync(observed_findings: [], actionable_findings: [], rows: { f.key => row },
      collected_categories: Set.new(%i[indexes]))

    expect(client).to have_received(:update_issue).with("viamin/paid", 7, state: "closed")
    expect(comments.first).to include("no longer observed", "2026-11-20T12:00:00Z")
    expect(result.closed).to eq(1)
    expect(row.reload.resolved_at).to be_present
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "does not close an issue for a category it could not observe" do
    f = finding
    row = row_for(f, github_issue_number: 7)

    result = filer.sync(observed_findings: [], actionable_findings: [], rows: { f.key => row },
      collected_categories: Set.new(%i[query_stats]))

    expect(client).not_to have_received(:update_issue)
    expect(client).not_to have_received(:add_comment)
    expect(result.closed).to eq(0)
    expect(row.reload.resolved_at).to be_nil
  end

  # @spec RAILS-CONTROL-PLANE-028
  it "caps new issues per run and preserves deferred findings for the next scan" do
    findings = (1..6).map { |i| finding(key: "invalid_index/public/idx_#{i}") }

    result = filer.sync(observed_findings: findings, actionable_findings: findings, rows: {},
      collected_categories: Set.new(%i[indexes]))

    expect(client).to have_received(:create_issue).exactly(Development::PgHeroOverview::Policy::MAX_NEW_ISSUES_PER_RUN).times
    expect(result.created).to eq(Development::PgHeroOverview::Policy::MAX_NEW_ISSUES_PER_RUN)
    expect(result.deferred).to eq(1)
    expect(result.deferred_keys).to contain_exactly("invalid_index/public/idx_6")
  end

  # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-029
  it "aborts before any write when the GitHub lookup fails" do
    allow(client).to receive(:all_issues).and_raise(GithubClient::Error.new("lookup failed"))

    expect {
      filer.sync(observed_findings: [ finding ], actionable_findings: [ finding ], rows: {},
        collected_categories: Set.new(%i[indexes]))
    }.to raise_error(GithubClient::Error)
    expect(client).not_to have_received(:create_issue)
    expect(PgHeroOverviewFinding.exists?(project: project, github_issue_number: nil,
      finding_key: "invalid_index/public/idx_broken")).to be(false)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "adopts an open GitHub issue carrying the finding marker when local state is missing" do
    f = finding
    allow(client).to receive(:all_issues) { [ github_issue(number: 31, body: filer.send(:body_for, f)) ] }

    filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: {}, collected_categories: Set.new(%i[indexes]))

    expect(client).not_to have_received(:create_issue)
    adopted = PgHeroOverviewFinding.find_by!(project: project, database: "primary", finding_key: f.key)
    expect(adopted.github_issue_number).to eq(31)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "adopts an existing issue when observation recording already created an unlinked row" do
    f = finding
    row = row_for(f)
    allow(client).to receive(:all_issues) { [ github_issue(number: 31, body: filer.send(:body_for, f)) ] }

    result = filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: { f.key => row },
      collected_categories: Set.new(%i[indexes]))

    expect(client).not_to have_received(:create_issue)
    expect(row.reload.github_issue_number).to eq(31)
    expect(result.created).to eq(0)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "recovers and reopens a closed issue after losing its local linkage" do
    f = finding
    row = row_for(f)
    allow(client).to receive(:all_issues).with("viamin/paid", labels: described_class::LABEL, state: "all")
      .and_return([ github_issue(number: 31, body: filer.send(:body_for, f), state: "closed") ])

    result = filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: { f.key => row },
      collected_categories: Set.new(%i[indexes]))

    expect(client).not_to have_received(:create_issue)
    expect(row.reload.github_issue_number).to eq(31)
    expect(client).to have_received(:update_issue).with("viamin/paid", 31, state: "open", body: kind_of(String))
    expect(result.reopened).to eq(1)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "prefers the oldest open issue when several issues match an unlinked finding" do
    f = finding
    row = row_for(f)
    allow(client).to receive(:all_issues) do
      [ github_issue(number: 3, body: filer.send(:body_for, f), state: "closed"),
        github_issue(number: 31, body: filer.send(:body_for, f)),
        github_issue(number: 7, body: filer.send(:body_for, f)) ]
    end

    filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: { f.key => row },
      collected_categories: Set.new(%i[indexes]))

    expect(row.reload.github_issue_number).to eq(7)
    expect(client).not_to have_received(:create_issue)
    expect(client).not_to have_received(:update_issue)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "preserves an existing issue link when other marked issues have the same identity" do
    f = finding
    row = row_for(f, github_issue_number: 7)
    allow(client).to receive(:all_issues) do
      [ github_issue(number: 31, body: filer.send(:body_for, f)),
        github_issue(number: 7, body: filer.send(:body_for, f)) ]
    end

    filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: { f.key => row },
      collected_categories: Set.new(%i[indexes]))

    expect(row.reload.github_issue_number).to eq(7)
    expect(client).not_to have_received(:create_issue)
    expect(client).not_to have_received(:update_issue)
  end

  # @spec RAILS-CONTROL-PLANE-027
  it "truncates oversized query text in issue bodies" do
    long_query = "SELECT * FROM issues WHERE token = $1 -- #{'x' * 5_000}"
    f = finding(type: :slow_query, key: "slow_query/5", category: :query_stats,
      observed: { query: long_query, average_ms: 150.0, calls: 9, threshold_ms: 100, threshold_calls: 5 })

    filer.sync(observed_findings: [ f ], actionable_findings: [ f ], rows: {}, collected_categories: Set.new(%i[query_stats]))

    expect(created_bodies.first.length).to be < long_query.length + 2_000
  end
end
