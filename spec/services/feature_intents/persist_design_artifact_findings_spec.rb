# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::PersistDesignArtifactFindings do
  let(:project) { create(:project, owner: "acme", repo: "widget") }
  let(:revision) { "a" * 40 }
  let(:artifact) { { path: "docs/rdrs/RDR-100.md", related_issues: [] } }

  it "persists one durable actionable finding per artifact revision" do
    2.times do
      described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    end

    finding = DesignArtifactFinding.sole
    expect(finding).to have_attributes(
      project:, account: project.account, artifact_path: "docs/rdrs/RDR-100.md",
      revision:, state: "missing_tree", status: "open"
    )
    expect(finding.evidence).to include("No explicit qualified issue links were found")
  end

  it "resolves an earlier finding when current explicit links cover the artifact" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])

    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(related_issues: [ "acme/widget#10" ]) ],
      issues: [ { repository: "acme/widget", number: 10 } ]
    )

    expect(DesignArtifactFinding.sole).to have_attributes(status: "resolved", resolved_at: be_present)
  end

  it "keeps an existing finding's coverage timestamp when a later scan is unverifiable" do
    travel_to(Time.zone.parse("2026-10-15 08:00:00 UTC")) do
      described_class.call(project:, revision:, artifacts: [ artifact ], issues: [], coverage_complete: false)
    end

    covered_at = DesignArtifactFinding.sole.covered_at

    travel_to(Time.zone.parse("2026-10-15 09:00:00 UTC")) do
      described_class.call(project:, revision:, artifacts: [ artifact ], issues: [], coverage_complete: false)
    end

    expect(DesignArtifactFinding.sole.covered_at).to eq(covered_at)
  end

  it "keeps an earlier actionable finding open when a later scan is unverifiable" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])

    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [], coverage_complete: false)

    expect(project.design_artifact_findings.open_findings.pluck(:state)).to contain_exactly("missing_tree", "unverifiable")
  end

  it "resolves an open RDR finding when its path was removed after a successful discovery" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])

    described_class.resolve_removed_rdr_findings(
      project:, paths: [], directory: "docs/rdrs", file_pattern: "RDR-*.md"
    )

    expect(DesignArtifactFinding.sole).to have_attributes(status: "resolved", resolved_at: be_present)
  end

  # @spec OPERATOR-INBOX-018
  it "resolves a deferred RDR finding when the underlying RDR is removed after reconciliation" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    finding = DesignArtifactFinding.sole
    finding.update!(status: "deferred", resolution_state: "deferred", resolution_reason: "out of scope")

    described_class.resolve_removed_rdr_findings(
      project:, paths: [], directory: "docs/rdrs", file_pattern: "RDR-*.md"
    )

    expect(finding.reload).to have_attributes(status: "resolved", resolved_at: be_present)
  end

  # @spec OPERATOR-INBOX-018
  it "resolves an assigned RDR finding when reconciliation verifies the gap is gone" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    finding = DesignArtifactFinding.sole
    finding.update!(status: "assigned", resolution_state: "assigned", resolution_reason: "owned by #1")

    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(related_issues: [ "acme/widget#10" ]) ],
      issues: [ { repository: "acme/widget", number: 10 } ]
    )

    expect(finding.reload).to have_attributes(status: "resolved", resolved_at: be_present)
  end

  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  it "reopens an assigned finding when its issue closes without resolving the gap" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    finding = DesignArtifactFinding.sole
    issue = create(:issue, :closed, project:)
    finding.update!(
      status: "assigned", resolution_state: "assigned", resolution_reason: "Owned by ##{issue.github_number}",
      resolution_issue: issue, resolution_metadata: { "revision" => revision }
    )

    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])

    expect(finding.reload).to have_attributes(
      status: "open", resolution_state: "assigned", resolution_issue: issue,
      resolution_metadata: include("reopened_reason" => "The assigned issue closed without reconciliation resolving this gap.")
    )
  end
end
