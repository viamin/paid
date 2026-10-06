# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::VerifyMergedRemediationAttempts do
  let(:project) { create(:project, default_branch: "main") }
  let(:issue) do
    create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1838)
  end
  let!(:attempt) do
    create(:code_scanning_remediation_attempt, issue:, pull_request_number: 4034,
      merge_commit_sha: "merge", merged_at: 1.hour.ago, tool_name: "CodeQL", category: "/language:ruby")
  end
  let(:github_client) { instance_double(GithubClient) }
  # Normalized shape produced by GithubClient#code_scanning_analyses from
  # documented GitHub responses (blank error = successful; no status field).
  let(:analysis) do
    { id: "1842809913", status: "succeeded", ref: "main", commit_sha: "descendant",
      tool_name: "CodeQL", category: "/language:ruby", error: "", warning: "", results_count: 7 }
  end

  def stub_analyses(analyses)
    allow(github_client).to receive(:code_scanning_analyses).with(project.full_name).and_return(analyses)
  end

  def stub_compare(status)
    allow(github_client).to receive(:compare).with(project.full_name, "merge", "descendant")
      .and_return(Struct.new(:status).new(status))
  end

  it "moves a recurrent finding to manual review using post-merge analysis evidence" do # @spec EAGER-QUEUE-013
    stub_analyses([ analysis ])
    stub_compare("ahead")

    described_class.new(project:, alerts: [ { number: 1838 } ], github_client:).call

    expect(attempt.reload.status).to eq("verification_failed")
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "records resolution when a matching post-merge analysis no longer reports the finding" do # @spec EAGER-QUEUE-013
    stub_analyses([ analysis ])
    stub_compare("identical")

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload.status).to eq("verified_fixed")
  end

  it "does not resolve from the merge or an aggregate result count while the alert is open" do # @spec EAGER-QUEUE-013
    stub_analyses([ analysis.merge(results_count: 0) ])
    stub_compare("identical")

    described_class.new(project:, alerts: [ { number: 1838 } ], github_client:).call

    expect(attempt.reload.status).to eq("verification_failed")
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "selects target-branch evidence instead of letting a newer PR-branch analysis hide it" do # @spec EAGER-QUEUE-013
    pr_branch_analysis = analysis.merge(id: "1842810001", ref: "refs/pull/4035/merge", commit_sha: "pr-head")
    stub_analyses([ pr_branch_analysis, analysis ])
    stub_compare("ahead")

    described_class.new(project:, alerts: [ { number: 1838 } ], github_client:).call

    expect(attempt.reload).to have_attributes(
      status: "verification_failed", verification_analysis_id: "1842809913", verification_ref: "main"
    )
    expect(github_client).not_to have_received(:compare).with(project.full_name, "merge", "pr-head")
  end

  it "falls through a newer error-bearing analysis to older successful evidence" do # @spec EAGER-QUEUE-013
    errored_analysis = analysis.merge(id: "1842810002", status: "failed", commit_sha: "broken", error: "processing timed out")
    stub_analyses([ errored_analysis, analysis ])
    stub_compare("ahead")

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload).to have_attributes(
      status: "verified_fixed", verification_analysis_id: "1842809913"
    )
    expect(github_client).not_to have_received(:compare).with(project.full_name, "merge", "broken")
  end

  it "blocks with the analysis error retained when every relevant analysis failed" do # @spec EAGER-QUEUE-013
    stub_analyses([ analysis.merge(status: "failed", error: "internal error", commit_sha: "broken") ])
    allow(github_client).to receive(:compare)

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload).to have_attributes(
      status: "verification_blocked", blocked_reason: "analysis did not succeed: internal error"
    )
    expect(attempt.reload.evidence).to include("analysis_error" => "internal error")
  end

  it "blocks verification when no matching post-merge analysis is available" do # @spec EAGER-QUEUE-013
    stub_analyses([])

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload).to have_attributes(status: "verification_blocked", blocked_reason: "analysis is unavailable")
  end

  it "retains configuration-mismatch evidence without comparing unrelated analyses" do # @spec EAGER-QUEUE-013
    unrelated_analysis = analysis.merge(tool_name: "Other scanner")
    stub_analyses([ unrelated_analysis ])
    allow(github_client).to receive(:compare)

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload.blocked_reason).to include("configuration differs")
    expect(github_client).not_to have_received(:compare)
  end
end
