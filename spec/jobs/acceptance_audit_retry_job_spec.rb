# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056
RSpec.describe AcceptanceAuditRetryJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "completed") }

  before do
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  def failed_attempt
    request = Issues::RequestAcceptanceAudit.call(issue:, actor: owner)
    request.agent_run.update!(status: "failed", completed_at: 2.hours.ago,
      reconciliation: { "acceptance_audit_failure" => { "category" => "transport_error" } })
    request.agent_run
  end

  describe ".retry_delay" do
    it "waits 30 minutes for the first retry and 60 minutes for the second" do
      expect(described_class.retry_delay(2)).to eq(30.minutes)
      expect(described_class.retry_delay(3)).to eq(60.minutes)
    end
  end

  describe "#perform" do
    it "claims the next attempt through the shared claim and re-queues processing" do
      original = failed_attempt

      expect {
        described_class.new.perform(original.id, 2)
      }.to change(AgentRun, :count).by(1)
        .and have_enqueued_job(ProcessRunQueueJob)

      expect(original.reload.status).to eq("retried")
      successor = AgentRun.order(:id).last
      expect(successor.goal).to eq("analyze_issue")
      expect(successor.external_metadata[AgentRun::ACCEPTANCE_AUDIT_RETRY_ATTEMPT_METADATA_KEY]).to eq(2)
    end

    it "cannot double-claim when a duplicate job is delivered" do
      original = failed_attempt

      described_class.new.perform(original.id, 2)
      described_class.new.perform(original.id, 2)

      expect(issue.agent_runs.count).to eq(2)
      expect(AgentRun.where(issue:, status: "queued").count).to eq(1)
    end

    it "leaves the failed attempt untouched when the claim is refused" do
      original = failed_attempt
      issue.update_columns(paused: true)

      expect {
        described_class.new.perform(original.id, 2)
      }.not_to change(AgentRun, :count)

      expect(original.reload.status).to eq("failed")
    end
  end
end
