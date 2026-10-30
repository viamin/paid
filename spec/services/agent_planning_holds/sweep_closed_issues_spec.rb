# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-019
RSpec.describe AgentPlanningHolds::SweepClosedIssues do
  let(:project) { create(:project) }

  it "resolves a linked hold's stale notification when its issue is closed" do
    issue = create(:issue, :closed, project:, labels: [ "planning" ])
    AgentPlanningHold.create!(account: project.account, project:, issue:, label: "planning", status: "needs_review")
    notification = create(:notification, :error, account: project.account, subject: issue,
      source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)

    reconciled = described_class.call

    expect(reconciled).to eq(1)
    expect(notification.reload.resolved_at).to be_present
  end

  it "resolves an unlinked hold by matching the closed issue's remote number within the same project" do
    issue = create(:issue, :closed, project:, labels: [ "planning" ])
    run = create(:agent_run, project:)
    hold = AgentPlanningHold.create!(account: project.account, project:, agent_run: run,
      remote_issue_number: issue.github_number, label: "planning", status: "needs_review")
    notification = create(:notification, :error, account: project.account, subject: run,
      source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)

    reconciled = described_class.call

    expect(reconciled).to eq(1)
    expect(notification.reload.resolved_at).to be_present
    expect(hold.reload.issue).to eq(issue)
  end

  it "leaves a hold untouched while its issue remains open" do
    issue = create(:issue, project:, labels: [ "planning" ])
    hold = AgentPlanningHold.create!(account: project.account, project:, issue:, label: "planning", status: "needs_review")

    reconciled = described_class.call

    expect(reconciled).to eq(0)
    expect(hold.reload.status).to eq("needs_review")
  end

  it "leaves an unlinked hold untouched when GitHub sync has not produced a matching local issue" do
    hold = AgentPlanningHold.create!(account: project.account, project:, remote_issue_number: 999_999,
      label: "planning", status: "needs_review")

    reconciled = described_class.call

    expect(reconciled).to eq(0)
    expect(hold.reload.issue).to be_nil
  end

  it "bounds a single sweep to the configured batch size" do
    3.times do |n|
      issue = create(:issue, :closed, project:, github_number: 9_000 + n, labels: [ "planning" ])
      AgentPlanningHold.create!(account: project.account, project:, issue:, label: "planning", status: "needs_review")
    end

    reconciled = described_class.call(batch_size: 2)

    expect(reconciled).to eq(2)
  end

  it "continues the batch after one hold fails to reconcile" do
    failing_issue = create(:issue, :closed, project:, labels: [ "planning" ])
    healthy_issue = create(:issue, :closed, project:, labels: [ "planning" ])
    failing_hold = AgentPlanningHold.create!(account: project.account, project:, issue: failing_issue,
      label: "planning", status: "needs_review")
    healthy_hold = AgentPlanningHold.create!(account: project.account, project:, issue: healthy_issue,
      label: "planning", status: "needs_review")
    allow(AgentPlanningHolds::Reconcile).to receive(:call).and_call_original
    allow(AgentPlanningHolds::Reconcile).to receive(:call).with(hold: failing_hold).and_raise(StandardError, "boom")

    reconciled = described_class.call

    expect(reconciled).to eq(1)
    expect(AgentPlanningHolds::Reconcile).to have_received(:call).with(hold: healthy_hold)
  end

  it "reconciles holds belonging to different accounts in one sweep" do
    other_project = create(:project)
    issue_one = create(:issue, :closed, project:, labels: [ "planning" ])
    issue_two = create(:issue, :closed, project: other_project, labels: [ "planning" ])
    AgentPlanningHold.create!(account: project.account, project:, issue: issue_one,
      label: "planning", status: "needs_review")
    AgentPlanningHold.create!(account: other_project.account, project: other_project, issue: issue_two,
      label: "planning", status: "needs_review")
    notification_one = create(:notification, :error, account: project.account, subject: issue_one,
      source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)
    notification_two = create(:notification, :error, account: other_project.account, subject: issue_two,
      source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)

    reconciled = described_class.call

    expect(reconciled).to eq(2)
    expect(notification_one.reload.resolved_at).to be_present
    expect(notification_two.reload.resolved_at).to be_present
  end
end
