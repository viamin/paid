# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-002
# @spec POST-DEPLOY-005
RSpec.describe PostDeployMeasurements::Checks::PlanningHoldNotifications do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:closed_issue) { create(:issue, :closed, project: project) }
  let(:open_issue) { create(:issue, project: project) }

  def notification_for(subject, account: self.account, **attributes)
    create(:notification, account: account, source: described_class::NOTIFICATION_SOURCE,
      subject: subject, severity: :error, blocking: true, **attributes)
  end

  describe "the registry entry" do
    it "defines the #4812 check with recorded baseline, target, and version" do
      check = described_class::CHECK

      expect(check.key).to eq("planning_hold_notifications_actionable")
      expect(check.version).to eq(1)
      expect(check.baseline).to eq(36)
      expect(check.target).to eq(0)
      expect(check.criterion).to include("agent_planning_hold_reconciliation")
      expect(check.measurer).to eq(described_class)
    end
  end

  describe ".measure" do
    it "counts active closed-source notifications as actionable" do
      notification_for(closed_issue)

      result = described_class.measure(project: project)

      expect(result.counts["actionable_closed_source"]).to eq(1)
      expect(result.counts["active_total"]).to eq(1)
    end

    it "separates open-source notifications so a closed-source zero stays interpretable" do
      notification_for(open_issue)

      result = described_class.measure(project: project)

      expect(result.counts["actionable_closed_source"]).to eq(0)
      expect(result.counts["active_open_source"]).to eq(1)
      expect(result.counts["active_total"]).to eq(1)
      expect(result.counts["resolved_total"]).to eq(0)
    end

    it "excludes resolved and dismissed notifications from the actionable count" do
      other_closed_issue = create(:issue, :closed, project: project)
      notification_for(closed_issue, resolved_at: Time.current)
      notification_for(other_closed_issue, dismissed_at: Time.current)

      result = described_class.measure(project: project)

      expect(result.counts["actionable_closed_source"]).to eq(0)
      expect(result.counts["active_total"]).to eq(0)
      expect(result.counts["resolved_total"]).to eq(1)
    end

    it "resolves AgentRun subjects through their issue" do
      run = create(:agent_run, project: project, issue: closed_issue)
      notification_for(run)

      other_run = create(:agent_run, project: project, issue: open_issue)
      notification_for(other_run)

      result = described_class.measure(project: project)

      expect(result.counts["actionable_closed_source"]).to eq(1)
      expect(result.counts["active_open_source"]).to eq(1)
      expect(result.counts["active_total"]).to eq(2)
    end

    it "scopes subjects to the measured project and reports the scope for provenance" do
      other_project = create(:project, account: account)
      notification_for(create(:issue, :closed, project: other_project))

      result = described_class.measure(project: project)

      expect(result.counts["actionable_closed_source"]).to eq(0)
      expect(result.counts["active_total"]).to eq(0)
      expect(result.scope).to include(
        "account_id" => account.id,
        "project_id" => project.id,
        "project" => project.full_name,
        "notification_source" => described_class::NOTIFICATION_SOURCE
      )
    end

    it "never counts another account's notifications", :tenant_isolation do
      own_account = TenantContext.with_system_access { create(:account) }
      other_account = TenantContext.with_system_access { create(:account) }
      own_project = nil
      TenantContext.with_system_access do
        own_project = create(:project, account: own_account)
        notification_for(create(:issue, :closed, project: own_project), account: own_account)
        other_project = create(:project, account: other_account)
        create(:notification, account: other_account, source: described_class::NOTIFICATION_SOURCE,
          subject: create(:issue, :closed, project: other_project), severity: :error)
      end

      TenantContext.with(own_account) do
        result = described_class.measure(project: own_project.reload)

        expect(result.counts["actionable_closed_source"]).to eq(1)
        expect(result.counts["active_total"]).to eq(1)
      end
    end

    it "issues only read-only statements" do
      notification_for(closed_issue)

      queries = capture_queries { described_class.measure(project: project) }

      expect(queries).to be_present
      expect(queries).to all(match(/\A\s*(SELECT|WITH)\b/i))
    end
  end
end
