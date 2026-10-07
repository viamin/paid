# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::ReconcileResolved do
  let(:project) { create(:project, default_branch: "main") }
  let!(:issue) do
    create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 42,
      github_state: "open", paid_state: "new")
  end

  def snapshot(alerts: [], complete: true, repository: project.full_name, branch: "main", configuration_scope: :all)
    SecurityAlerts::CodeScanningSnapshot.new(
      repository:, branch:, configuration_scope:, complete:, alerts:
    )
  end

  it "does not close a finding from an empty snapshot without explicit disposition" do # @spec GITHUB-SYNC-018
    described_class.new(project, snapshot: snapshot).call

    expect(issue.reload).to have_attributes(github_state: "open", paid_state: "new")
  end

  it "does not close a finding from an incomplete or filtered snapshot" do # @spec GITHUB-SYNC-018
    described_class.new(project, snapshot: snapshot(complete: false)).call
    described_class.new(project, snapshot: snapshot(configuration_scope: :filtered)).call

    expect(issue.reload.github_state).to eq("open")
  end

  it "closes a dismissed finding without claiming a verified code fix" do # @spec GITHUB-SYNC-018
    result = snapshot(alerts: [ {
      number: 42, state: "dismissed", dismissed_reason: "won't fix", html_url: "https://example.test/42"
    } ])
    expect(result.authoritative_for?(project)).to be(true)

    described_class.new(project, snapshot: result).call

    expect(issue.reload).to have_attributes(
      github_state: "closed", paid_state: "manual_review", code_scanning_disposition: "dismissed",
      code_scanning_disposition_reason: "won't fix"
    )
  end

  it "leaves one configuration's active finding open when another is fixed" do # @spec GITHUB-SYNC-018
    described_class.new(project, snapshot: snapshot(alerts: [
      { number: 42, state: "open", tool_name: "CodeQL", category: "/ruby" },
      { number: 42, state: "fixed", tool_name: "CodeQL", category: "/javascript" }
    ])).call

    expect(issue.reload.github_state).to eq("open")
  end
end
