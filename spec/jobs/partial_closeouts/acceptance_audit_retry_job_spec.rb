# frozen_string_literal: true

# frozen_string: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056
RSpec.describe PartialCloseouts::AcceptanceAuditRetryJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
  let(:issue) do
    issue = create(:issue, project:, github_state: "open", paid_state: "completed")
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
    issue
  end
  let(:source_revision) { PartialCloseouts::Assessment.source_revision_for(issue) }
  let(:intent_revision) { PartialCloseouts::Assessment.intent_revision_for(issue) }

  def failed_transient_audit
    request = create(:issue_continuation_request, issue:, project:, status: "consumed",
      evidence: { "merged_prs" => [], "source_revision" => source_revision, "intent_revision" => intent_revision,
        "continuation_mode" => "acceptance_audit" },
      evidence_digest: source_revision)
    create(:agent_run, :automatic, project:, issue:, goal: "analyze_issue",
      continuation_request: request, status: "failed",
      error_message: "Partial closeout assessment transport failed. Retry after runner recovery.",
      completed_at: 2.hours.ago)
  end

  describe ".retry_delay" do
    it "waits 30 minutes before the second attempt and 60 before the third" do
      expect(described_class.retry_delay(2)).to eq(30.minutes)
      expect(described_class.retry_delay(3)).to eq(60.minutes)
    end
  end

  describe "#perform" do
    it "claims one retry through the shared mechanism and re-queues processing" do
      original = failed_transient_audit

      expect { described_class.new.perform(original.id, 2) }
        .to change(AgentRun, :count).by(1)
        .and have_enqueued_job(ProcessRunQueueJob).at_least(:once)

      expect(original.reload.status).to eq("retried")

      successor = AgentRun.order(:id).last
      expect(successor.goal).to eq("analyze_issue")
      expect(successor.auto_pick).to be(true)
      expect(successor.continuation_request.evidence["continuation_mode"]).to eq("acceptance_audit")

      decision = OrchestrationDecision.last
      expect(decision.actor).to eq("acceptance_audit_auto_retry")
      expect(decision.agent_run).to eq(original)
      expect(decision.inputs).to include("attempt" => 2, "max_attempts" => 3)
      expect(decision.outputs["new_agent_run_id"]).to eq(successor.id)
    end

    it "resolves a duplicate delivery to a durable no-op without minting another audit" do
      original = failed_transient_audit
      described_class.new.perform(original.id, 2)

      expect { described_class.new.perform(original.id, 2) }.not_to change(AgentRun, :count)
      expect(issue.agent_runs.count).to eq(2)
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("already_retried")
    end

    it "records a durable refusal reason for a deterministic failure instead of retrying" do
      original = failed_transient_audit
      original.update!(error_message: "Partial closeout assessment returned invalid JSON.",
        reconciliation: { "acceptance_audit_failure" => { "category" => "invalid_json" } })

      expect { described_class.new.perform(original.id, 2) }.not_to change(AgentRun, :count)
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("invalid_input")
    end

    it "refuses to claim a retry whose evidence generation changed so a stale attempt cannot publish" do
      original = failed_transient_audit
      create(:issue, :pull_request, project:, parent_issue: issue, github_number: 13,
        github_state: "closed", pr_review_phase: "merged")

      expect { described_class.new.perform(original.id, 2) }.not_to change(AgentRun, :count)
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("evidence_changed")
    end

    it "does not loop when the attempt budget for the evidence generation is exhausted" do
      original = failed_transient_audit
      2.times do
        request = create(:issue_continuation_request, issue:, project:, status: "consumed",
          evidence: { "merged_prs" => [], "source_revision" => source_revision, "intent_revision" => intent_revision,
            "continuation_mode" => "acceptance_audit" },
          evidence_digest: source_revision)
        create(:agent_run, :automatic, project:, issue:, goal: "analyze_issue",
          continuation_request: request, status: "failed",
          error_message: "Partial closeout assessment transport failed. Retry after runner recovery.",
          completed_at: 2.hours.ago)
      end

      expect { described_class.new.perform(original.id, 3) }.not_to change(AgentRun, :count)
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("retry_exhausted")
    end
  end
end
