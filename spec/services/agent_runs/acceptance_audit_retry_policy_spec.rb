# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056 AGENT-RETRY-016
RSpec.describe AgentRuns::AcceptanceAuditRetryPolicy do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "completed") }
  let(:policy) { described_class.new }

  before do
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  def audit_run(status:, category: "transport_error", completed_at: 2.hours.ago, error_message: nil)
    request = Issues::RequestAcceptanceAudit.call(issue:, actor: owner)
    run = request.agent_run
    reconciliation = category ? { "acceptance_audit_failure" => { "category" => category } } : {}
    run.update!(status:, completed_at:, reconciliation:, error_message:)
    run
  end

  def assessment(run)
    run.continuation_request.evidence
  end

  describe ".acceptance_audit_run?" do
    it "recognizes only runs authorized by an acceptance-audit continuation" do
      audit = audit_run(status: "failed")
      implementation = create(:agent_run, project:, issue:, goal: "create_pr", status: "failed")

      expect(described_class).to be_acceptance_audit_run(audit)
      expect(described_class).not_to be_acceptance_audit_run(implementation)
    end
  end

  describe "#assess" do
    it "admits a transiently failed attempt with budget remaining" do
      run = audit_run(status: "failed")

      result = policy.assess(run)

      expect(result.eligible?).to be(true)
      expect(result.reason).to eq(:eligible)
      expect(result.attempt).to eq(2)
    end

    it "refuses a run that is not an acceptance-audit attempt" do
      other = create(:agent_run, project:, issue:, goal: "analyze_issue", status: "failed")

      expect(policy.assess(other).reason).to eq(:not_acceptance_audit)
    end

    it "refuses a completed substantive assessment even when it reported unmet criteria" do
      run = audit_run(status: "completed", category: nil)
      run.update!(reconciliation: { "assessment" => { "gaps" => [ { "criterion" => "c", "kind" => "agent", "title" => "t" } ] } })

      expect(policy.assess(run).reason).to eq(:substantive_assessment_recorded)
    end

    it "refuses a cancelled attempt and an already-retried attempt" do
      expect(policy.assess(audit_run(status: "cancelled")).reason).to eq(:cancelled)

      retried = audit_run(status: "failed")
      retried.update!(status: "retried")
      expect(policy.assess(retried).reason).to eq(:already_retried)
    end

    it "refuses an authentication/configuration failure instead of retrying it as transport" do
      run = audit_run(status: "failed", category: "authentication_unavailable")

      expect(policy.assess(run).reason).to eq(:authentication_or_configuration)
    end

    it "refuses a deterministic failure message" do
      run = audit_run(status: "failed", category: nil,
        error_message: "Partial closeout assessment could not authenticate with the configured runner.")

      expect(policy.assess(run).reason).to eq(:non_transient_failure)
    end

    it "refuses once the source revision's attempt budget is exhausted, counting operator attempts" do
      3.times { audit_run(status: "failed") }

      newest = issue.agent_runs.order(:id).last
      result = policy.assess(newest)

      expect(result.attempt).to eq(4)
      expect(result.reason).to eq(:retry_budget_exhausted)
    end

    it "refuses when terminal evidence changed the logical identity" do
      run = audit_run(status: "failed")
      create(:issue, :pull_request, project:, parent_issue: issue, github_number: 13,
        github_state: "closed", pr_review_phase: "merged")

      expect(policy.assess(run).reason).to eq(:evidence_changed)
    end

    it "refuses while another continuation authorization is open" do
      run = audit_run(status: "failed")
      Issues::RequestAcceptanceAudit.call(issue:, actor: owner)

      expect(policy.assess(run).reason).to eq(:open_request_present)
    end
  end

  describe "logical identity and lineage" do
    it "counts every attempt against the run's source revision, including retried lineage" do
      first = audit_run(status: "failed")
      expect(policy.attempt_count(first)).to eq(1)
      expect(policy.logical_source_revision(first)).to eq(assessment(first)["source_revision"])

      first.update!(status: "retried")
      second = audit_run(status: "failed")

      expect(policy.attempt_count(second)).to eq(2)
      expect(policy.next_attempt(second)).to eq(3)
      expect(policy.maximum_attempts).to eq(3)
    end
  end
end
