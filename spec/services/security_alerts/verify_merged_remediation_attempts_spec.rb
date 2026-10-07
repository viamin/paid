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
  let(:analysis) do
    { id: "1842809913", status: "succeeded", ref: "main", commit_sha: "descendant",
      tool_name: "CodeQL", category: "/language:ruby" }
  end

  it "moves a recurrent finding to manual review using post-merge analysis evidence" do # @spec EAGER-QUEUE-013
    allow(github_client).to receive(:code_scanning_analyses).with(project.full_name).and_return([ analysis ])
    allow(github_client).to receive(:compare).with(project.full_name, "merge", "descendant")
      .and_return(Struct.new(:status).new("ahead"))

    described_class.new(project:, alerts: [ { number: 1838, state: "open" } ], github_client:).call

    expect(attempt.reload.status).to eq("verification_failed")
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "records resolution when a matching post-merge analysis no longer reports the finding" do # @spec EAGER-QUEUE-013
    allow(github_client).to receive(:code_scanning_analyses).with(project.full_name).and_return([ analysis ])
    allow(github_client).to receive(:compare).with(project.full_name, "merge", "descendant")
      .and_return(Struct.new(:status).new("identical"))

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload.status).to eq("verified_fixed")
  end

  it "passes an upstream dismissal to verification rather than treating it as an absent alert" do # @spec EAGER-QUEUE-013 GITHUB-SYNC-018
    allow(github_client).to receive(:code_scanning_analyses).with(project.full_name).and_return([ analysis ])
    allow(github_client).to receive(:compare).with(project.full_name, "merge", "descendant")
      .and_return(Struct.new(:status).new("identical"))

    described_class.new(
      project:, alerts: [ { number: 1838, state: "dismissed", dismissed_reason: "false positive" } ], github_client:
    ).call

    expect(attempt.reload.status).to eq("verification_blocked")
  end

  it "blocks verification when no matching post-merge analysis is available" do # @spec EAGER-QUEUE-013
    allow(github_client).to receive(:code_scanning_analyses).with(project.full_name).and_return([])

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload).to have_attributes(status: "verification_blocked", blocked_reason: "analysis is unavailable")
  end

  it "retains configuration-mismatch evidence without comparing unrelated analyses" do # @spec EAGER-QUEUE-013
    unrelated_analysis = analysis.merge(tool_name: "Other scanner")
    allow(github_client).to receive(:code_scanning_analyses).with(project.full_name).and_return([ unrelated_analysis ])
    allow(github_client).to receive(:compare)

    described_class.new(project:, alerts: [], github_client:).call

    expect(attempt.reload.blocked_reason).to include("configuration differs")
    expect(github_client).not_to have_received(:compare)
  end
end
