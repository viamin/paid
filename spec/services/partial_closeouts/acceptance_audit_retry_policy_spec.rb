# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056 AGENT-RETRY-014
RSpec.describe PartialCloseouts::AcceptanceAuditRetryPolicy do
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
  let(:policy) { described_class.new }

  def audit_run(status: "failed", error_message: nil, revision: source_revision, recorded_intent: intent_revision,
    reconciliation: {})
    request = create(:issue_continuation_request, issue:, project:, status: "consumed",
      evidence: { "merged_prs" => [], "source_revision" => revision, "intent_revision" => recorded_intent,
        "continuation_mode" => "acceptance_audit" },
      evidence_digest: revision)
    create(:agent_run, :automatic, project:, issue:, goal: "analyze_issue",
      continuation_request: request, status:, error_message:, reconciliation:)
  end

  describe "#assess" do
    it "admits a bounded retry for a transient failure with no usable assessment under the same evidence" do
      run = audit_run(error_message: "Partial closeout assessment transport failed. Retry after runner recovery.")

      assessment = policy.assess(run)

      expect(assessment.eligible?).to be(true)
      expect(assessment.attempt).to eq(2)
    end

    it "refuses a run that is not an acceptance-audit attempt" do
      run = create(:agent_run, :automatic, :failed, project:, issue:, goal: "analyze_issue")

      expect(policy.assess(run).reason).to eq(:not_acceptance_audit)
    end

    it "refuses a duplicate claim of an attempt that already produced its successor" do
      run = audit_run(status: "retried", error_message: "Partial closeout assessment transport failed.")

      expect(policy.assess(run).reason).to eq(:already_retried)
    end

    it "refuses the retry while another continuation authorization is open, keeping overlap idempotent" do
      run = audit_run(error_message: "Partial closeout assessment transport failed.")
      create(:issue_continuation_request, issue:, project:, status: "queued",
        evidence: { "merged_prs" => [], "continuation_mode" => "acceptance_audit",
          "source_revision" => source_revision, "intent_revision" => intent_revision },
        evidence_digest: source_revision)

      expect(policy.assess(run).reason).to eq(:open_request_exists)
    end

    it "refuses the retry when a current substantive assessment already exists" do
      run = audit_run(error_message: "Partial closeout assessment transport failed.")
      completed = audit_run(status: "completed", revision: source_revision, recorded_intent: intent_revision,
        reconciliation: { "assessment" => { "source_revision" => source_revision,
          "intent_revision" => intent_revision, "gaps" => [], "criteria" => [] } })
      completed.update!(completed_at: Time.current)

      expect(policy.assess(run).reason).to eq(:substantive_assessment)
    end

    it "refuses the retry when the terminal evidence changed, so a stale retry cannot publish a current result" do
      run = audit_run(error_message: "Partial closeout assessment transport failed.",
        revision: "stale-revision")

      expect(policy.assess(run).reason).to eq(:evidence_changed)
    end

    it "refuses deterministic failures by classification instead of retrying them" do
      expect(policy.assess(audit_run(error_message: "Audit returned garbage")).reason).to eq(:non_transient_failure)
      expect(policy.assess(audit_run(reconciliation: {
        "acceptance_audit_failure" => { "category" => "invalid_json" }
      })).reason).to eq(:invalid_input)
      expect(policy.assess(audit_run(error_message: "Partial closeout assessment could not authenticate with the configured runner. Reconnect its credential and retry.")).reason)
        .to eq(:authentication_configuration)
      expect(policy.assess(audit_run(status: "cancelled")).reason).to eq(:cancellation)
      expect(policy.assess(audit_run(status: "token_budget_exceeded")).reason).to eq(:budget_exhausted)
    end

    it "stops after the bounded attempt budget for one evidence generation" do
      3.times do
        audit_run(error_message: "Partial closeout assessment transport failed. Retry after runner recovery.")
      end
      latest = issue.agent_runs.order(:id).last
      latest.update!(completed_at: 2.hours.ago)

      assessment = policy.assess(latest)

      expect(assessment.reason).to eq(:retry_exhausted)
      expect(assessment.attempt).to eq(3)
    end

    it "refuses the retry when automatic scheduling is disabled for the project" do
      project.update!(auto_pick_enabled: false)
      run = audit_run(error_message: "Partial closeout assessment transport failed.")

      expect(policy.assess(run).reason).to eq(:automation_disabled)
    end
  end

  describe "shared retry-contract surface" do
    it "exposes the bounded budget and increasing backoff delays" do
      expect(policy.maximum_attempts).to eq(3)
      expect(described_class.retry_delay(2)).to eq(30.minutes)
      expect(described_class.retry_delay(3)).to eq(60.minutes)
    end

    it "names its own durable decision action so audit reasons are not recorded as manual-run retries" do
      expect(policy.decision_action).to eq("acceptance_audit_auto_retry")
    end

    it "recognizes the one-open-request unique index as its duplicate-claim conflict" do
      error = ActiveRecord::RecordNotUnique.new(
        "PG::UniqueViolation: ERROR: duplicate key value violates unique constraint \"index_issue_continuation_requests_open_per_issue\""
      )
      def error.cause = nil

      expect(policy.duplicate_active_run_conflict?(error)).to be(true)
      expect(policy.duplicate_conflict_reason).to eq(:open_request_exists)
    end

    it "builds the successor through ordinary audit admission, not a raw run copy" do
      run = audit_run(error_message: "Partial closeout assessment transport failed.")

      successor = policy.build_successor!(run, 2)

      expect(successor.goal).to eq("analyze_issue")
      expect(successor.auto_pick).to be(true)
      expect(successor.status).to eq("queued")
      expect(successor.continuation_request.evidence["continuation_mode"]).to eq("acceptance_audit")
      expect(successor.continuation_request.evidence["source_revision"]).to eq(source_revision)
    end
  end
end
