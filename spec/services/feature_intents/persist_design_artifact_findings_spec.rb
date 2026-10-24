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

  # @spec OPERATOR-INBOX-020 DESIGN-RECONCILIATION-001
  it "persists a draft artifact's informational finding as deferred without inventing an operator decision" do
    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(status: "Draft") ], issues: []
    )

    expect(DesignArtifactFinding.sole).to have_attributes(
      state: "deferred", status: "deferred",
      resolution_state: nil, resolution_actor: nil, resolved_at: nil
    )
    expect(project.design_artifact_findings.actionable_findings).to be_empty
  end

  # @spec OPERATOR-INBOX-020 DESIGN-RECONCILIATION-001
  it "reconciles a previously open informational finding back out of the open action status" do
    create(:design_artifact_finding, project:, account: project.account,
      artifact_path: artifact[:path], revision:, state: "deferred", status: "open",
      evidence: [ "Artifact status is Draft" ])

    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(status: "Draft") ], issues: []
    )

    expect(project.design_artifact_findings.open_findings).to be_empty
    expect(project.design_artifact_findings.actionable_findings).to be_empty
    expect(project.design_artifact_findings.where(state: "deferred", status: "deferred")).to be_present
  end

  # @spec OPERATOR-INBOX-020
  it "invalidates the inbox cache when reconciliation retires a fingerprint-matched noisy finding" do
    fingerprint = Digest::SHA256.hexdigest([ project.id, artifact[:path], revision, "deferred" ].join(":"))
    create(:design_artifact_finding, project:, account: project.account,
      artifact_path: artifact[:path], revision:, fingerprint:, state: "deferred", status: "open",
      evidence: [ "Artifact status is Draft" ])
    allow(Dashboard::CacheVersion).to receive(:bump).and_call_original

    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(status: "Draft") ], issues: []
    )

    expect(Dashboard::CacheVersion).to have_received(:bump)
      .with(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end

  # @spec OPERATOR-INBOX-020
  it "does not resurrect an unchanged informational finding on revision refresh" do
    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(status: "Superseded") ], issues: []
    )

    travel_to(1.day.from_now) do
      described_class.call(
        project:, revision: "b" * 40, artifacts: [ artifact.merge(status: "Superseded") ], issues: []
      )
    end

    expect(project.design_artifact_findings.count).to eq(1)
    expect(project.design_artifact_findings.sole).to have_attributes(
      revision: "b" * 40, state: "deferred", status: "deferred"
    )
    expect(project.design_artifact_findings.open_findings).to be_empty
  end

  # @spec OPERATOR-INBOX-020 DESIGN-RECONCILIATION-001
  it "resolves the informational record and surfaces actionable work when a draft artifact becomes active" do
    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(status: "Draft") ], issues: []
    )
    informational = DesignArtifactFinding.sole

    described_class.call(project:, revision: "b" * 40, artifacts: [ artifact ], issues: [])

    expect(informational.reload).to have_attributes(status: "resolved", resolved_at: be_present)
    expect(project.design_artifact_findings.actionable_findings.sole).to have_attributes(
      revision: "b" * 40, state: "missing_tree", status: "open"
    )
  end

  # @spec OPERATOR-INBOX-020 DESIGN-RECONCILIATION-001
  it "resolves the open actionable finding when an active artifact becomes superseded" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    actionable = DesignArtifactFinding.sole

    described_class.call(
      project:, revision: "b" * 40, artifacts: [ artifact.merge(status: "Superseded") ], issues: []
    )

    expect(actionable.reload).to have_attributes(status: "resolved", resolved_at: be_present)
    expect(project.design_artifact_findings.actionable_findings).to be_empty
    expect(project.design_artifact_findings.where(state: "deferred")).to be_present
  end

  # @spec OPERATOR-INBOX-020
  it "preserves an operator decision recorded on an informational finding" do
    described_class.call(
      project:, revision:, artifacts: [ artifact.merge(status: "Draft") ], issues: []
    )
    finding = DesignArtifactFinding.sole
    finding.update!(status: "dismissed", resolution_state: "dismissed", resolution_reason: "Tracked elsewhere")

    described_class.call(
      project:, revision: "b" * 40, artifacts: [ artifact.merge(status: "Draft") ], issues: []
    )

    expect(DesignArtifactFinding.sole).to have_attributes(
      status: "dismissed", resolution_reason: "Tracked elsewhere"
    )
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

  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  it "carries a deferred decision across an unrelated artifact revision" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    finding = DesignArtifactFinding.sole
    finding.update!(status: "deferred", resolution_state: "deferred", resolution_reason: "Awaiting a planned documentation update")

    described_class.call(project:, revision: "b" * 40, artifacts: [ artifact ], issues: [])

    expect(DesignArtifactFinding.sole).to have_attributes(
      revision: "b" * 40, status: "deferred", resolution_reason: "Awaiting a planned documentation update"
    )
  end

  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  it "carries a dismissed decision across an unrelated artifact revision" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    finding = DesignArtifactFinding.sole
    finding.update!(status: "dismissed", resolution_state: "dismissed", resolution_reason: "Not applicable to this historical document")

    described_class.call(project:, revision: "b" * 40, artifacts: [ artifact ], issues: [])

    expect(DesignArtifactFinding.sole).to have_attributes(
      revision: "b" * 40, status: "dismissed", resolution_reason: "Not applicable to this historical document"
    )
  end

  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  it "reopens a deferred decision when the reconciliation evidence materially changes" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])
    finding = DesignArtifactFinding.sole
    finding.update!(status: "deferred", resolution_state: "deferred", resolution_reason: "Awaiting a planned documentation update")

    described_class.call(
      project:, revision: "b" * 40, artifacts: [ artifact.merge(stored_identities: [ "acme/widget#10" ]) ], issues: []
    )

    expect(project.design_artifact_findings.open_findings.sole).to have_attributes(
      revision: "b" * 40, state: "stale_metadata"
    )
  end

  it "resolves an open RDR finding when its path was removed after a successful discovery" do
    described_class.call(project:, revision:, artifacts: [ artifact ], issues: [])

    described_class.resolve_removed_rdr_findings(
      project:, paths: [], directory: "docs/rdrs", file_pattern: "RDR-*.md"
    )

    expect(DesignArtifactFinding.sole).to have_attributes(status: "resolved", resolved_at: be_present)
  end

  # @spec DESIGN-RECONCILIATION-001
  it "resolves the directory-level unavailable sentinel after complete discovery" do
    sentinel = create(:design_artifact_finding, project:, account: project.account,
      artifact_path: "docs/rdrs", revision: "main", state: "unverifiable")

    described_class.resolve_removed_rdr_findings(
      project:, paths: [], directory: "docs/rdrs", file_pattern: "RDR-*.md"
    )

    expect(sentinel.reload).to have_attributes(status: "resolved", resolved_at: be_present)
  end

  # @spec DESIGN-RECONCILIATION-001
  it "keeps an identical finding in another tenant untouched" do
    other_project = create(:project)
    other = create(:design_artifact_finding, project: other_project, account: other_project.account,
      artifact_path: "docs/rdrs/RDR-100.md", revision: revision)

    described_class.resolve_removed_rdr_findings(
      project:, paths: [], directory: "docs/rdrs", file_pattern: "RDR-*.md"
    )

    expect(other.reload.status).to eq("open")
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
