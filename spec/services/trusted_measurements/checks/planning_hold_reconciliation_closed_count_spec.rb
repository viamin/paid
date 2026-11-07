# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-002
RSpec.describe TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount do
  let(:project) { create(:project) }
  let(:source) { described_class::NOTIFICATION_SOURCE }

  describe ".call" do
    it "counts only active notifications whose source issue is closed, and reports the broader active total" do
      closed_issue = create(:issue, :closed, project:)
      open_issue = create(:issue, project:)
      create(:notification, account: project.account, source:, subject: closed_issue)
      create(:notification, account: project.account, source:, subject: open_issue)

      result = described_class.call(project:)

      expect(result.active_total).to eq(2)
      expect(result.active_closed_issue_count).to eq(1)
      expect(result.baseline).to eq(36)
      expect(result.target).to eq(0)
      expect(result.project_scope).to eq("project:#{project.id}:#{project.full_name}")
    end

    it "excludes resolved and dismissed notifications even when their issue is closed" do
      resolved_issue = create(:issue, :closed, project:)
      dismissed_issue = create(:issue, :closed, project:)
      create(:notification, :resolved, account: project.account, source:, subject: resolved_issue)
      create(:notification, :dismissed, account: project.account, source:, subject: dismissed_issue)

      result = described_class.call(project:)

      expect(result.active_total).to eq(0)
      expect(result.active_closed_issue_count).to eq(0)
    end

    it "excludes notifications scoped to a different project in the same account" do
      other_project = create(:project, account: project.account)
      other_closed_issue = create(:issue, :closed, project: other_project)
      create(:notification, account: project.account, source:, subject: other_closed_issue)

      result = described_class.call(project:)

      expect(result.active_total).to eq(0)
      expect(result.active_closed_issue_count).to eq(0)
    end

    # Real RLS enforcement for this query is covered by the restricted-role
    # suite in spec/security/tenant_context_spec.rb; the default spec
    # environment's database role bypasses RLS, so this only proves the
    # check's own query scopes by account, not that the database backstops it.
    it "excludes another tenant's notifications even when the two accounts use identical project ids locally" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)
      other_closed_issue = create(:issue, :closed, project: other_project)
      create(:notification, account: other_account, source:, subject: other_closed_issue)

      result = described_class.call(project:)

      expect(result.active_total).to eq(0)
      expect(result.active_closed_issue_count).to eq(0)
    end

    it "is read-only" do
      closed_issue = create(:issue, :closed, project:)
      notification = create(:notification, account: project.account, source:, subject: closed_issue)
      attributes_before = notification.reload.attributes

      described_class.call(project:)

      expect(notification.reload.attributes).to eq(attributes_before)
    end

    it "reflects a notification resolved between two runs instead of a cached count" do
      closed_issue = create(:issue, :closed, project:)
      notification = create(:notification, account: project.account, source:, subject: closed_issue)

      expect(described_class.call(project:).active_closed_issue_count).to eq(1)

      notification.update!(resolved_at: Time.current)

      expect(described_class.call(project:).active_closed_issue_count).to eq(0)
    end
  end
end
