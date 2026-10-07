# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::VerifyRemediationAttempt do
  let(:project) { create(:project, default_branch: "main") }
  let(:issue) do
    create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
  end
  let(:attempt) do
    create(:code_scanning_remediation_attempt, issue:, pull_request_number: 4034,
      merge_commit_sha: "merge", merged_at: 1.hour.ago, tool_name: "CodeQL", category: "/language:ruby")
  end
  # Normalized shape produced by GithubClient#code_scanning_analyses from a
  # documented GitHub response: a blank error (not a status field) is what a
  # successful analysis looks like.
  let(:analysis) do
    { id: "1842809913", status: "succeeded", ref: "main", commit_sha: "descendant",
      tool_name: "CodeQL", category: "/language:ruby", error: "", warning: "", results_count: 7 }
  end

  def verify(alert: nil, analysis: self.analysis, contains_merge_commit: true)
    described_class.new(attempt:, alert:, analysis:, contains_merge_commit:).call
  end

  it "moves an unresolved post-merge finding to manual review without retrying" do # @spec EAGER-QUEUE-013
    verify(alert: { number: 1838, state: "open" })

    expect(attempt.reload).to have_attributes(status: "verification_failed", verification_analysis_id: "1842809913")
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "records scanner-confirmed resolution only from matching post-merge evidence" do # @spec EAGER-QUEUE-013
    verify

    expect(attempt.reload.status).to eq("verified_fixed")
  end

  it "blocks a dismissed upstream finding instead of recording a verified fix" do # @spec EAGER-QUEUE-013 GITHUB-SYNC-019
    verify(alert: { number: 1838, state: "dismissed", dismissed_reason: "false positive" })

    expect(attempt.reload).to have_attributes(
      status: "verification_blocked", blocked_reason: "finding was dismissed upstream: false positive"
    )
    expect(attempt.evidence).to include("alert_state" => "dismissed", "dismissed_reason" => "false positive")
  end

  it "blocks another upstream disposition instead of recording a verified fix" do # @spec EAGER-QUEUE-013
    verify(alert: { number: 1838, state: "fixed" })

    expect(attempt.reload).to have_attributes(
      status: "verification_blocked", blocked_reason: "finding has upstream disposition: fixed"
    )
    expect(attempt.evidence).to include("alert_state" => "fixed")
  end

  it "does not resolve from an aggregate result count when the alert is still open" do # @spec EAGER-QUEUE-013
    verify(alert: { number: 1838, state: "open" }, analysis: analysis.merge(results_count: 0))

    expect(attempt.reload).to have_attributes(status: "verification_failed")
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "blocks instead of resolving for pending, wrong-branch, or old analyses" do # @spec EAGER-QUEUE-013
    verify(analysis: analysis.merge(status: "in_progress"))
    expect(attempt.reload.status).to eq("verification_blocked")

    verify(analysis: analysis.merge(ref: "feature"))
    expect(attempt.reload.blocked_reason).to include("target branch")

    verify(contains_merge_commit: false)
    expect(attempt.reload.blocked_reason).to include("does not contain")
  end

  it "blocks on error-bearing analyses and retains the error detail as evidence" do # @spec EAGER-QUEUE-013
    verify(analysis: analysis.merge(status: "failed", error: "processing timed out after 30m0s"))

    expect(attempt.reload).to have_attributes(
      status: "verification_blocked",
      blocked_reason: "analysis did not succeed: processing timed out after 30m0s"
    )
    expect(attempt.reload.evidence).to include("analysis_error" => "processing timed out after 30m0s")
  end

  it "blocks on malformed analyses that cannot affirm success" do # @spec EAGER-QUEUE-013
    verify(analysis: analysis.merge(status: "malformed", ref: nil))

    expect(attempt.reload).to have_attributes(
      status: "verification_blocked", blocked_reason: "analysis evidence is malformed"
    )
  end

  it "does not resolve from a malformed analysis even when both attempt and analysis have nil configuration" do
    # @spec EAGER-QUEUE-013
    nil_attempt = create(:code_scanning_remediation_attempt, issue:, pull_request_number: 4035,
      merge_commit_sha: "merge", merged_at: 1.hour.ago, tool_name: nil, category: nil)
    nil_analysis = analysis.merge(status: "malformed", tool_name: nil, category: nil)

    described_class.new(attempt: nil_attempt, alert: nil, analysis: nil_analysis,
      contains_merge_commit: true).call

    expect(nil_attempt.reload).to have_attributes(
      status: "verification_blocked", blocked_reason: "analysis evidence is malformed"
    )
  end

  it "does not use alert updated_at as scan freshness evidence" do # @spec EAGER-QUEUE-013
    verify(alert: { number: 1838, state: "open", updated_at: 3.months.ago })

    expect(attempt.reload.status).to eq("verification_failed")
  end

  it "records unavailable analysis evidence without raising" do # @spec EAGER-QUEUE-013
    expect { verify(analysis: nil, contains_merge_commit: false) }.not_to raise_error

    expect(attempt.reload).to have_attributes(
      status: "verification_blocked", blocked_reason: "analysis is unavailable"
    )
  end

  describe "blocked-attempt re-verification" do
    before do
      attempt.update!(status: "verification_blocked", blocked_reason: "analysis is unavailable",
        evidence: { "prior_attempt_at" => 1.hour.ago.iso8601 })
    end

    it "preserves the blocked status on a re-verification that still cannot confirm the fix" do # @spec EAGER-QUEUE-014
      verify(analysis: analysis.merge(status: "in_progress"))

      expect(attempt.reload.status).to eq("verification_blocked")
      expect(attempt.blocked_reason).to include("did not succeed")
      expect(attempt.evidence).to include("prior_attempt_at")
    end

    it "transitions a blocked attempt to verified_fixed when the alert is no longer reported" do # @spec EAGER-QUEUE-014
      verify

      expect(attempt.reload.status).to eq("verified_fixed")
    end

    it "transitions a blocked attempt to verification_failed when the alert is still open" do # @spec EAGER-QUEUE-014
      verify(alert: { number: 1838, state: "open" })

      expect(attempt.reload.status).to eq("verification_failed")
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    it "does not re-move the issue to manual_review on a subsequent re-confirmation" do # @spec EAGER-QUEUE-014
      issue.update!(paid_state: "manual_review", manual_review_reason: "operator-attached reason")
      attempt.update!(status: "verification_failed", blocked_reason: "prior")

      verify(alert: { number: 1838, state: "open" })

      expect(attempt.reload.status).to eq("verification_failed")
      expect(issue.reload.manual_review_reason).to eq("operator-attached reason")
    end
  end
end
