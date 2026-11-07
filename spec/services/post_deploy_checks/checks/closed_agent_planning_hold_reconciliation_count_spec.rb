# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-CHECK-006 POST-DEPLOY-CHECK-010
RSpec.describe PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:other_project) { create(:project, account:) }

  def active_reconciliation_notification(issue)
    create(:notification, account: issue.project.account, source: described_class::NOTIFICATION_SOURCE,
      subject: issue, blocking: true, severity: :error)
  end

  it "counts active notifications whose source issue is closed, separately from the active total" do
    closed_issue = create(:issue, :closed, project:)
    open_issue = create(:issue, project:)
    active_reconciliation_notification(closed_issue)
    active_reconciliation_notification(open_issue)

    result = described_class.call(project:)

    expect(result.active_total).to eq(2)
    expect(result.active_with_closed_source).to eq(1)
    expect(result.baseline).to eq(36)
    expect(result.target).to eq(0)
    expect(result).not_to be_met_target
  end

  it "reports a target met when no active notification has a closed source issue" do
    open_issue = create(:issue, project:)
    active_reconciliation_notification(open_issue)

    result = described_class.call(project:)

    expect(result.active_total).to eq(1)
    expect(result.active_with_closed_source).to eq(0)
    expect(result).to be_met_target
  end

  it "distinguishes a project with no active notifications from one that already meets target" do
    result = described_class.call(project:)

    expect(result.active_total).to eq(0)
    expect(result.active_with_closed_source).to eq(0)
    expect(result).to be_met_target
  end

  it "excludes resolved and dismissed notifications" do
    resolved_issue = create(:issue, :closed, project:)
    dismissed_issue = create(:issue, :closed, project:)
    create(:notification, :resolved, account:, source: described_class::NOTIFICATION_SOURCE, subject: resolved_issue)
    create(:notification, :dismissed, account:, source: described_class::NOTIFICATION_SOURCE, subject: dismissed_issue)

    result = described_class.call(project:)

    expect(result.active_total).to eq(0)
    expect(result.active_with_closed_source).to eq(0)
  end

  it "scopes strictly to issues belonging to the authorized project (tenant/project isolation)" do
    closed_issue = create(:issue, :closed, project: other_project)
    active_reconciliation_notification(closed_issue)

    result = described_class.call(project:)

    expect(result.active_total).to eq(0)
    expect(result.active_with_closed_source).to eq(0)
  end

  it "ignores notifications from an unrelated source" do
    closed_issue = create(:issue, :closed, project:)
    create(:notification, account:, source: "unrelated_source", subject: closed_issue, blocking: true, severity: :error)

    result = described_class.call(project:)

    expect(result.active_total).to eq(0)
  end
end
