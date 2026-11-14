# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::NoProgressCreatePrHold do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }

  def record_no_progress_run
    revisions = {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue)
    }
    create(:agent_run, :completed, :automatic, project:, issue:, goal: "create_pr", auto_pick: true,
      pull_request_number: nil, pull_request_url: nil, result_commit_sha: nil,
      reconciliation: { "no_progress" => revisions.merge("outcome" => "recommend_close") })
  end

  it "does not hold a single no-progress implementation run" do # @spec NO-OUTPUT-ISSUE-009
    record_no_progress_run

    expect(described_class.held_issue_ids(project)).to be_empty
  end

  it "holds repeated no-progress runs for unchanged evidence and names an operator action" do # @spec NO-OUTPUT-ISSUE-009
    first = record_no_progress_run
    second = record_no_progress_run

    expect(described_class.held_issue_ids(project)).to contain_exactly(issue.id)
    expect(described_class.diagnostic_for(issue)).to include(
      reason: "repeated_no_progress_create_pr",
      run_ids: contain_exactly(first.id, second.id),
      next_action: "Update acceptance evidence or request an authorized retry."
    )
  end

  it "releases the hold when issue intent changes" do # @spec NO-OUTPUT-ISSUE-009
    2.times { record_no_progress_run }
    issue.update!(body: "Changed acceptance criterion")

    expect(described_class.held_issue_ids(project)).to be_empty
  end

  it "resets the consecutive sequence when an intervening run produces a commit" do # @spec NO-OUTPUT-ISSUE-009
    record_no_progress_run
    create(:agent_run, :completed, :automatic, project:, issue:, goal: "create_pr", auto_pick: true,
      pull_request_number: nil, result_commit_sha: "abc123")
    record_no_progress_run

    expect(described_class.held_issue_ids(project)).to be_empty
  end

  it "does not treat provider failures as no-progress outcomes" do # @spec NO-OUTPUT-ISSUE-009
    2.times do
      create(:agent_run, :failed, :automatic, project:, issue:, goal: "create_pr", auto_pick: true,
        reconciliation: { "no_progress" => { "outcome" => "provider_error" } })
    end

    expect(described_class.held_issue_ids(project)).to be_empty
  end
end
