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
end
