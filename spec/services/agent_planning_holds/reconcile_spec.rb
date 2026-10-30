# frozen_string_literal: true

require "rails_helper"

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
end
