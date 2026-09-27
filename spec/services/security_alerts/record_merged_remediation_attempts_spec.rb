# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::RecordMergedRemediationAttempts do
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1838,
      github_number: SecurityAlerts::ProcessCodeScanningAlerts::SYNTHETIC_NUMBER_OFFSET + 1838)
  end
  let!(:run) { create(:agent_run, project:, issue:, pull_request_number: 4034) }
  let!(:pull_request) do
    create(:issue, :pull_request, project:, github_number: 4034, parent_issue: issue,
      github_state: "closed", pr_review_phase: "merged")
  end
  let(:github_client) { instance_double(GithubClient) }

  it "records the GitHub merge commit once and awaits verification" do # @spec EAGER-QUEUE-013
    run
    pull_request
    github_pr = Struct.new(:merge_commit_sha, :merged_at).new("b" * 40, Time.current)
    allow(github_client).to receive(:pull_request).with(project.full_name, 4034).and_return(github_pr)

    described_class.new(project:, alerts: [ { number: 1838,
      tool_name: "CodeQL", category: "/language:ruby" } ], github_client:).call

    expect(issue.code_scanning_remediation_attempts.last).to have_attributes(
      pull_request_number: 4034, merge_commit_sha: "b" * 40, status: "awaiting_verification"
    )
  end
end
