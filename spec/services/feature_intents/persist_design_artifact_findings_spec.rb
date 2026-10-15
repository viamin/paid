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

  it "resolves an open RDR finding when its path was removed after a successful discovery" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])

    described_class.resolve_removed_rdr_findings(
      project:, paths: [], directory: "docs/rdrs", file_pattern: "RDR-*.md"
    )

    expect(DesignArtifactFinding.sole).to have_attributes(status: "resolved", resolved_at: be_present)
  end
end
