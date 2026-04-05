# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260404062147_add_draft_review_round_tracking_to_agent_runs")

RSpec.describe AddDraftReviewRoundTrackingToAgentRuns, :aggregate_failures do
  let(:migration) { described_class.new }
  let(:project) { create(:project) }
  let(:draft_review_count) { 3 }

  it "backfills unfinished automatic draft followups with the expected draft count" do
    tracked_run = create_run(:running, trigger_type: "automatic", source_pull_request_number: 42)
    manual_run = create_run(:running, trigger_type: "manual", source_pull_request_number: 43)
    completed_run = create_run(:completed, trigger_type: "automatic", source_pull_request_number: 44)

    migration.send(:backfill_legacy_draft_followup_runs!)

    [ tracked_run, manual_run, completed_run ].each(&:reload)
    expect(tracked_run.count_toward_draft_review_round).to be(true)
    expect(tracked_run.expected_draft_review_count).to eq(draft_review_count)
    expect(manual_run.count_toward_draft_review_round).to be(false)
    expect(manual_run.expected_draft_review_count).to be_nil
    expect(completed_run.count_toward_draft_review_round).to be(false)
    expect(completed_run.expected_draft_review_count).to be_nil
  end

  def create_run(*traits, **attributes)
    issue = create(:issue, :pull_request, project: project,
      pr_review_phase: "draft",
      draft_review_count: draft_review_count)
    create(:agent_run, *traits, project: project, issue: issue, **attributes)
  end
end
