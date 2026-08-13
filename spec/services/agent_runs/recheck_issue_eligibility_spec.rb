# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::RecheckIssueEligibility do # @spec EAGER-QUEUE-005 @spec EAGER-QUEUE-006
  let(:project) { create(:project, auto_pick_enabled: true) }

  # Builds a queued auto-pick run for +issue+. The issue is created in its
  # target state BEFORE the run so update callbacks (closed/paused label
  # sync, orphan-run cancellation) don't fire — this isolates the recheck.
  def queued_auto_pick_run(issue:, goal: "create_pr", **attrs)
    create(
      :agent_run,
      :queued,
      project: project,
      issue: issue,
      goal: goal,
      trigger_type: "automatic",
      auto_pick: true,
      **attrs
    )
  end

  it "does not cancel an eligible issue's run and returns false" do
    issue = create(:issue, project: project, github_state: "open")
    run = queued_auto_pick_run(issue: issue)

    expect(described_class.call(run)).to be false

    run.reload
    expect(run.status).to eq("queued")
    expect(run.temporal_workflow_id).to be_nil
  end

  it "cancels the run when the issue carries an auto-pick skip label" do
    issue = create(:issue, project: project, github_state: "open", labels: [ "planning" ])
    run = queued_auto_pick_run(issue: issue)

    expect(described_class.call(run)).to be true

    run.reload
    expect(run.status).to eq("cancelled")
    expect(run.error_message).to include("no longer eligible")
  end

  it "cancels the run when paid_state is in a skip state" do
    issue = create(:issue, project: project, github_state: "open", paid_state: "needs_input")
    run = queued_auto_pick_run(issue: issue)

    expect(described_class.call(run)).to be true
    expect(run.reload.status).to eq("cancelled")
  end

  it "cancels the run when the issue is blocked by an open dependency" do
    dependent = create(:issue, project: project, github_state: "open")
    blocker = create(:issue, project: project, github_state: "open")
    create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
    run = queued_auto_pick_run(issue: dependent)

    expect(described_class.call(run)).to be true
    expect(run.reload.status).to eq("cancelled")
  end

  it "cancels the run when the issue is closed on GitHub" do
    issue = create(:issue, project: project, github_state: "closed")
    run = queued_auto_pick_run(issue: issue)

    expect(described_class.call(run)).to be true
    expect(run.reload.status).to eq("cancelled")
  end

  it "cancels the run when the issue is paused" do
    issue = create(:issue, project: project, github_state: "open")
    # Bypass the after_commit paid-paused label sync to GitHub — the
    # recheck only cares about the local flag.
    issue.update_columns(paused: true, paused_at: Time.current)
    run = queued_auto_pick_run(issue: issue)

    expect(described_class.call(run)).to be true
    expect(run.reload.status).to eq("cancelled")
  end

  it "does not cancel a manual run even when its issue is ineligible" do
    issue = create(:issue, project: project, github_state: "open", labels: [ "planning" ])
    run = create(:agent_run, :queued, project: project, issue: issue,
      trigger_type: "manual", auto_pick: false)

    expect(described_class.call(run)).to be false
    expect(run.reload.status).to eq("queued")
  end

  it "does not cancel a run with no issue" do
    run = create(:agent_run, :queued, :automatic, :with_custom_prompt,
      project: project, auto_pick: true)

    expect(described_class.call(run)).to be false
    expect(run.reload.status).to eq("queued")
  end

  it "does not cancel a review goal run" do
    run = create(:agent_run, :queued, :automatic, :review_goal,
      project: project, auto_pick: true)

    expect(described_class.call(run)).to be false
    expect(run.reload.status).to eq("queued")
  end

  it "does not cancel a run that was already claimed (race protection)" do
    issue = create(:issue, project: project, github_state: "open", labels: [ "planning" ])
    run = queued_auto_pick_run(issue: issue)
    run.update_columns(temporal_workflow_id: AgentRun::CLAIMED_SENTINEL)

    expect(described_class.call(run)).to be false
    expect(run.reload.status).to eq("queued")
  end

  it "keeps an eligible run queued for a completed issue awaiting re-seed" do
    # A completed issue with no PR-producing run is still auto-pick
    # eligible (infrastructure failure recovery), so its queued run must
    # not be cancelled.
    issue = create(:issue, project: project, github_state: "open", paid_state: "completed")
    create(:agent_run, :completed, :automatic, project: project, issue: issue,
      goal: "create_pr", auto_pick: true, pull_request_number: nil, pull_request_url: nil)
    run = queued_auto_pick_run(issue: issue)

    expect(described_class.call(run)).to be false
    expect(run.reload.status).to eq("queued")
  end
end
