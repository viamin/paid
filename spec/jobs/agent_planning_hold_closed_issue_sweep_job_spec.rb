# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-019
RSpec.describe AgentPlanningHoldClosedIssueSweepJob do
  it "delegates to the bounded sweep service and logs the reconciled count" do
    allow(AgentPlanningHolds::SweepClosedIssues).to receive(:call).and_return(3)
    allow(Rails.logger).to receive(:info)

    described_class.perform_now

    expect(AgentPlanningHolds::SweepClosedIssues).to have_received(:call)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "agent_planning_holds.closed_issue_sweep_completed", reconciled_count: 3)
    )
  end

  # :tenant_isolation opts this example out of rails_helper's blanket
  # system-access wrap so the job's own ApplicationJob#with_tenant_context
  # (which falls back to system access for an argument-less job) is what
  # makes cross-account reconciliation possible here, not the test harness.
  it "reconciles holds across every tenant with no ambient tenant context", :tenant_isolation do
    notification_one = TenantContext.with_system_access { build_closed_issue_notification }
    notification_two = TenantContext.with_system_access { build_closed_issue_notification }
    TenantContext.clear!

    described_class.perform_now

    TenantContext.with_system_access do
      expect(notification_one.reload.resolved_at).to be_present
      expect(notification_two.reload.resolved_at).to be_present
    end
  end

  def build_closed_issue_notification
    account = create(:account)
    project = create(:project, account: account)
    issue = create(:issue, :closed, project: project, labels: [ "planning" ])
    AgentPlanningHold.create!(account: account, project: project, issue: issue, label: "planning", status: "needs_review")
    create(:notification, :error, account: account, subject: issue,
      source: AgentPlanningHolds::RequestReview::SOURCE, blocking: true)
  end
end
