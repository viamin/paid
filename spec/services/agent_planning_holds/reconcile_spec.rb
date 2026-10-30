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
  describe "when the hold's own issue is already closed" do
    let(:closed_issue) { create(:issue, :closed, project:, labels: [ "planning" ]) }

    it "resolves the stale notification without releasing the label or claiming approval" do
      hold = AgentPlanningHold.create!(
        account: project.account, project:, issue: closed_issue, agent_run: run, label: "planning", status: "needs_review"
      )
      notification = create(:notification, :error, account: project.account, subject: closed_issue,
        source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)
      expect(project.client).not_to receive(:remove_label_from_issue)

      result = described_class.call(hold:)

      expect(result).not_to be_released
      expect(notification.reload.resolved_at).to be_present
      expect(hold.reload.status).to eq("needs_review")
      expect(closed_issue.reload.labels).to include("planning")
    end

    it "resolves a notification keyed on the agent run before the issue had synchronized locally" do
      hold = AgentPlanningHold.create!(
        account: project.account, project:, agent_run: run, remote_issue_number: closed_issue.github_number,
        label: "planning", status: "needs_review"
      )
      notification = create(:notification, :error, account: project.account, subject: run,
        source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)

      result = described_class.call(hold:)

      expect(result).not_to be_released
      expect(notification.reload.resolved_at).to be_present
      expect(hold.reload.issue).to eq(closed_issue)
    end

    it "does not attempt a mechanical release even when the recorded condition would otherwise be satisfied" do
      hold = AgentPlanningHold.create!(
        account: project.account, project:, issue: closed_issue, agent_run: run, label: "planning", status: "held",
        task_kind: "implementation", reason: "Awaiting dependency resolution.",
        release_condition: { "kind" => "dependencies_resolved" }, evidence: { "scope_revision" => "v1" }
      )
      expect(project.client).not_to receive(:remove_label_from_issue)

      result = described_class.call(hold:)

      expect(result).not_to be_released
      expect(hold.reload.status).to eq("held")
    end

    it "does not auto-approve an operator-override hold just because the issue closed" do
      hold = AgentPlanningHold.create!(
        account: project.account, project:, issue: closed_issue, agent_run: run, label: "planning", status: "held",
        task_kind: "planning", reason: "Awaiting design approval.", operator_override: true,
        release_condition: { "kind" => "dependencies_resolved" }, evidence: { "scope_revision" => "v1" }
      )
      notification = create(:notification, :error, account: project.account, subject: closed_issue,
        source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)
      expect(project.client).not_to receive(:remove_label_from_issue)

      result = described_class.call(hold:)

      expect(result).not_to be_released
      expect(hold.reload).to have_attributes(status: "held", operator_override: true)
      expect(notification.reload.resolved_at).to be_present
      expect(closed_issue.reload.labels).to include("planning")
    end
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
