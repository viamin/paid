# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::VerifyRemediationAttempt do
  let(:project) { create(:project, default_branch: "main") }
  let(:issue) { create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE) }
  let(:attempt) do
    create(:code_scanning_remediation_attempt, issue:, pull_request_number: 4034,
      merge_commit_sha: "merge", merged_at: 1.hour.ago, tool_name: "CodeQL", category: "/language:ruby")
  end
  let(:analysis) { { id: "1842809913", status: "succeeded", ref: "main", commit_sha: "descendant", tool_name: "CodeQL", category: "/language:ruby" } }

  def verify(alert: nil, analysis: self.analysis, contains_merge_commit: true)
    described_class.new(attempt:, alert:, analysis:, contains_merge_commit:).call
  end

  it "moves an unresolved post-merge finding to manual review without retrying" do # @spec EAGER-QUEUE-013
    verify(alert: { number: 1838 })

    expect(attempt.reload).to have_attributes(status: "verification_failed", verification_analysis_id: "1842809913")
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "records scanner-confirmed resolution only from matching post-merge evidence" do # @spec EAGER-QUEUE-013
    verify

    expect(attempt.reload.status).to eq("verified_fixed")
  end

  it "blocks instead of resolving for pending, wrong-branch, or old analyses" do # @spec EAGER-QUEUE-013
    verify(analysis: analysis.merge(status: "in_progress"))
    expect(attempt.reload.status).to eq("verification_blocked")

    verify(analysis: analysis.merge(ref: "feature"))
    expect(attempt.reload.blocked_reason).to include("target branch")

    verify(contains_merge_commit: false)
    expect(attempt.reload.blocked_reason).to include("does not contain")
  end

  it "does not use alert updated_at as scan freshness evidence" do # @spec EAGER-QUEUE-013
    verify(alert: { number: 1838, updated_at: 3.months.ago })

    expect(attempt.reload.status).to eq("verification_failed")
  end

  it "records unavailable analysis evidence without raising" do # @spec EAGER-QUEUE-013
    expect { verify(analysis: nil, contains_merge_commit: false) }.not_to raise_error

    expect(attempt.reload).to have_attributes(
      status: "verification_blocked", blocked_reason: "analysis is unavailable"
    )
  end
end
