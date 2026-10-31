# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec CONFIDENCE-DELIVERY-018
RSpec.describe AgentPlanningHolds::Reconcile do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, labels: [ "planning" ]) }
  let(:run) { create(:agent_run, project:) }
  let(:hold) do
    create_agent_hold(
      release_condition: { "kind" => "issue_closed", "issue_number" => issue.github_number + 100 },
      status: "held"
    )
  end

  it "does not release a distinct post-shadow decision when another issue closes" do
    create(:issue, :closed, project:, github_number: issue.github_number + 99)

    result = described_class.call(hold:)

    expect(result).not_to be_released
    expect(hold.reload.status).to eq("held")
  end

  it "records a label API failure for retry" do
    create(:issue, :closed, project:, github_number: issue.github_number + 100)
    allow(project.client).to receive(:remove_label_from_issue).and_raise(GithubClient::Error, "unavailable")

    result = described_class.call(hold:)

    expect(result).not_to be_released
    expect(hold.reload).to have_attributes(status: "reconciliation_failed", last_error: "unavailable")
  end

  it "finishes reconciliation when a retry finds the label already absent" do
    create(:issue, :closed, project:, github_number: issue.github_number + 100)
    allow(project.client).to receive(:remove_label_from_issue)
      .and_raise(GithubClient::NotFoundError, "Label not found")
    allow(project.client).to receive(:issue).and_return(remote_issue(labels: []))

    result = described_class.call(hold:)

    expect(result).to be_released
    expect(hold.reload).to have_attributes(status: "released", last_error: nil)
    expect(issue.reload.labels).to be_empty
  end

  it "releases an ordinary agent hold after its originating run finishes" do
    run.update!(status: "failed", completed_at: Time.current)
    ordinary_hold = create_agent_hold(
      release_condition: { "kind" => "agent_run_finished", "agent_run_id" => run.id },
      status: "held"
    )
    allow(project.client).to receive(:remove_label_from_issue)
    allow(project.client).to receive(:issue).and_return(remote_issue(labels: []))

    result = described_class.call(hold: ordinary_hold)

    expect(result).to be_released
    expect(ordinary_hold.reload.status).to eq("released")
  end

  it "routes a previously captured unsupported condition to operator review" do
    unsupported_hold = create_agent_hold(
      release_condition: { "kind" => "design_revision_accepted", "issue_number" => issue.github_number },
      status: "held"
    )

    result = described_class.call(hold: unsupported_hold)

    expect(result).not_to be_released
    expect(unsupported_hold.reload.status).to eq("needs_review")
    expect(Notification.where(source: "agent_planning_hold_reconciliation", subject: issue).blocking).to exist
  end

  # @spec CONFIDENCE-DELIVERY-019
  it "resolves an obsolete review request for a closed issue without removing its label" do
    issue.update!(github_state: "closed")
    unsupported_hold = create_agent_hold(
      release_condition: { "kind" => "design_revision_accepted", "issue_number" => issue.github_number },
      status: "needs_review"
    )
    notification = AgentPlanningHolds::RequestReview.call(hold: unsupported_hold)

    expect(project.client).not_to receive(:remove_label_from_issue)

    result = described_class.call(hold: unsupported_hold)

    expect(result).not_to be_released
    expect(issue.reload.labels).to eq([ "planning" ])
    expect(notification.reload.resolved_at).to be_present
    expect(unsupported_hold.reload.evidence.fetch("closure_resolutions").last).to include("status" => "needs_review")
  end

  # @spec CONFIDENCE-DELIVERY-019
  it "creates one fresh request when a closed unsupported hold reopens" do
    issue.update!(github_state: "closed")
    unsupported_hold = create_agent_hold(
      release_condition: { "kind" => "design_revision_accepted", "issue_number" => issue.github_number },
      status: "needs_review"
    )
    previous_notification = AgentPlanningHolds::RequestReview.call(hold: unsupported_hold)
    described_class.call(hold: unsupported_hold)
    issue.update!(github_state: "open")

    described_class.call(hold: unsupported_hold)
    described_class.call(hold: unsupported_hold)

    expect(previous_notification.reload.metadata.fetch("resolution_history").map { |event| event.fetch("action") })
      .to include("closed_issue", "reopened")
    expect(issue.reload.labels).to include("planning")
    expect(Notification.where(source: "agent_planning_hold_reconciliation", subject: issue).active.count).to eq(1)
  end

  it "attaches a receipt to the issue after a later GitHub synchronization" do
    delayed_hold = AgentPlanningHold.create!(
      account: project.account,
      project: project,
      remote_issue_number: issue.github_number,
      label: "planning",
      status: "held",
      task_kind: "implementation",
      reason: "Awaiting a documented release condition.",
      release_condition: { "kind" => "issue_closed", "issue_number" => issue.github_number + 100 },
      evidence: { "scope_revision" => "v1" }
    )

    result = described_class.call(hold: delayed_hold)

    expect(result).not_to be_released
    expect(delayed_hold.reload.issue).to eq(issue)
  end

  # @spec CONFIDENCE-DELIVERY-019
  it "resolves a stale run-subject review request after the closed issue synchronizes" do
    issue.update!(github_state: "closed")
    delayed_hold = AgentPlanningHold.create!(
      account: project.account,
      project: project,
      agent_run: run,
      remote_issue_number: issue.github_number,
      label: "planning",
      status: "needs_review"
    )
    notification = AgentPlanningHolds::RequestReview.call(hold: delayed_hold)

    described_class.call(hold: delayed_hold)

    expect(delayed_hold.reload.issue).to eq(issue)
    expect(notification.reload.resolved_at).to be_present
  end

  private

  def create_agent_hold(release_condition:, status:)
    AgentPlanningHold.create!(
      account: project.account,
      project:,
      issue:,
      agent_run: run,
      label: "planning",
      status:,
      task_kind: "implementation",
      reason: "Awaiting a documented release condition.",
      release_condition:,
      evidence: { "scope_revision" => "v1" }
    )
  end

  def remote_issue(labels:)
    OpenStruct.new(
      id: issue.github_issue_id,
      number: issue.github_number,
      title: issue.title,
      body: issue.body,
      html_url: issue.github_html_url,
      state: issue.github_state,
      labels:,
      pull_request: nil,
      state_reason: nil,
      user: OpenStruct.new(login: issue.github_creator_login),
      created_at: issue.github_created_at,
      updated_at: issue.github_updated_at
    )
  end
end
