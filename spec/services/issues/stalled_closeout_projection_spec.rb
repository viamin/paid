# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::StalledCloseoutProjection do # @spec PARTIAL-CLOSEOUT-042 @spec PARTIAL-CLOSEOUT-043
  let(:account) { create(:account) }
  let(:project) do
    create(:project, account:, auto_pick_enabled: true, owner: "acme", repo: "alpha")
  end

  before do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
  end

  it "persists a successful empty checkpoint so evaluated projects are distinct from unevaluated projects" do
    result = described_class.call(project:)

    expect(result.checkpoint.computed_at).to be_present
    expect(result.checkpoint.entries).to be_empty
    expect(PartialCloseoutProjectionEntry.where(project:)).to be_empty
  end

  it "replaces the projected stall atomically and the reader returns the persisted lane entry" do # @spec PARTIAL-CLOSEOUT-042
    issue = create(:issue, project:, github_state: "open", paid_state: "in_progress")
    create(:issue, :pull_request, project:, parent_issue_id: issue.id, github_state: "closed",
      pr_review_phase: "merged", github_number: issue.github_number + 100)

    described_class.call(project:)

    pairs = described_class.read([ project ])

    expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(issue.id)
    expect(project.reload.partial_closeout_projection.entries.count).to eq(1)
  end

  it "restores closeout and technical evidence in batches for projected entries" do # @spec PARTIAL-CLOSEOUT-042
    issues = 2.times.map { create_stalled_issue(project) }
    issues.each do |issue|
      create(:agent_run, :completed, project:, issue:, reconciliation: {
        TechnicalPrerequisites::Evidence::RECONCILIATION_KEY => { "revision" => issue.id }
      })
    end
    described_class.call(project:)

    projected_pairs = nil
    queries = capture_sql { projected_pairs = described_class.read([ project ]) }

    expect(projected_pairs.map { |pair| pair.status.technical_evidence })
      .to match_array(issues.map { |issue| [ { "revision" => issue.id } ] })
    expect(queries.count { |sql| sql.include?("merged_prs") }).to be <= 2
    expect(queries.count { |sql| sql.include?(TechnicalPrerequisites::Evidence::RECONCILIATION_KEY) }).to eq(1)
  end

  it "allows a project with projected entries to be deleted" do # @spec PARTIAL-CLOSEOUT-042
    create_stalled_issue(project)
    described_class.call(project:)

    expect { project.destroy! }.to change(PartialCloseoutProjectionEntry, :count).by(-1)
  end

  it "retains the last successful rows when recomputation fails" do
    issue = create(:issue, project:, github_state: "open", paid_state: "in_progress")
    create(:issue, :pull_request, project:, parent_issue_id: issue.id, github_state: "closed",
      pr_review_phase: "merged", github_number: issue.github_number + 100)
    described_class.call(project:)
    generation = project.reload.partial_closeout_projection.generation

    allow(Issues::StalledCloseouts).to receive(:call).and_raise("projection failure")

    expect { described_class.call(project:) }.to raise_error("projection failure")
    checkpoint = project.reload.partial_closeout_projection
    expect(checkpoint.generation).to eq(generation)
    expect(checkpoint.entries).to contain_exactly(have_attributes(issue_id: issue.id))
    expect(checkpoint.last_failure).to include("class" => "RuntimeError")
  end

  it "falls back live only for projection-enabled projects without a successful checkpoint" do
    evaluated = project
    unevaluated = create(:project, account:, auto_pick_enabled: true, owner: "acme", repo: "beta")
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project: unevaluated)
    evaluated_issue = create_stalled_issue(evaluated)
    unevaluated_issue = create_stalled_issue(unevaluated)
    described_class.call(project: evaluated)

    pairs = described_class.read([ evaluated, unevaluated ])

    expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(evaluated_issue.id, unevaluated_issue.id)
  end

  it "loads projection checkpoints in one query across projects" do # @spec PARTIAL-CLOSEOUT-043
    other_project = create(:project, account:, auto_pick_enabled: true, owner: "acme", repo: "beta")
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project: other_project)
    [ project, other_project ].each { |target| described_class.call(project: target) }

    queries = capture_sql { described_class.read([ project, other_project ]) }

    checkpoint_queries = queries.select do |sql|
      sql.include?('FROM "partial_closeout_projections"') && sql.include?('"computed_at" IS NOT NULL')
    end
    expect(checkpoint_queries.one?).to be(true)
  end

  def create_stalled_issue(target_project)
    issue = create(:issue, project: target_project, github_state: "open", paid_state: "in_progress")
    create(:issue, :pull_request, project: target_project, parent_issue_id: issue.id, github_state: "closed",
      pr_review_phase: "merged", github_number: issue.github_number + 100)
    issue
  end

  def capture_sql
    statements = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      statements << payload[:sql] unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION])
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    statements
  end
end
