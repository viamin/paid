# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceRuns::IntentTraceabilityEvidence do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def render(max_findings: 2, max_associations: 2)
    described_class.call(project:, max_findings:, max_associations:)
  end

  # @spec MAINT-046
  it "lists pending findings with path, state, status, coverage recency, and evidence" do
    create(:design_artifact_finding, project:, artifact_path: "docs/rdrs/RDR-063.md", state: "missing_tree",
      status: "open", evidence: [ "No explicit qualified issue links were found" ],
      covered_at: Time.utc(2026, 11, 1, 12, 0, 0))

    snapshot = render

    expect(snapshot).to include("docs/rdrs/RDR-063.md")
    expect(snapshot).to include("missing_tree")
    expect(snapshot).to include("open")
    expect(snapshot).to include("2026-11-01T12:00:00Z")
    expect(snapshot).to include("No explicit qualified issue links were found")
  end

  # @spec MAINT-046
  it "identifies the assigned resolution issue of an assigned finding" do
    issue = create(:issue, project:, github_number: 41)
    create(:design_artifact_finding, project:, artifact_path: "docs/rdrs/RDR-070.md", state: "partial_tree",
      status: "assigned", resolution_issue: issue)

    expect(render).to include("#{project.full_name}#41")
  end

  it "summarizes resolved findings by count instead of listing every row" do
    create(:design_artifact_finding, project:, artifact_path: "docs/rdrs/RDR-063.md", state: "stale_metadata",
      status: "resolved", resolved_at: Time.current)

    snapshot = render

    expect(snapshot).to match(/resolved.*stale_metadata.*1|stale_metadata.*resolved.*1/i)
    expect(snapshot).not_to include("docs/rdrs/RDR-063.md")
  end

  # @spec MAINT-046
  it "lists stored associations as known trees with identity and provenance" do
    create(:design_artifact_association, project:, artifact_path: "docs/rdrs/RDR-063.md",
      issue_identity: "acme/forager#12", provenance: "canonical issue-tree manifest")

    snapshot = render

    expect(snapshot).to include("docs/rdrs/RDR-063.md")
    expect(snapshot).to include("acme/forager#12")
    expect(snapshot).to include("canonical issue-tree manifest")
  end

  it "discloses findings and associations omitted beyond the snapshot bounds" do
    create_list(:design_artifact_finding, 3, project:)
    create_list(:design_artifact_association, 3, project:)

    snapshot = render

    expect(snapshot).to match(/\(\+1 (more|additional|further) (pending )?finding/i)
    expect(snapshot).to match(/\(\+1 (more|additional|further) association/i)
  end

  it "reports state counts that cover findings beyond the listed page" do
    create_list(:design_artifact_finding, 3, project:, state: "partial_tree")

    snapshot = render(max_findings: 1)

    expect(snapshot).to include("partial_tree 3")
    expect(snapshot).to match(/\(\+2 more pending findings/i)
  end

  # @spec MAINT-046
  it "states absent reconciliation evidence as a coverage limitation, not a clean result" do
    snapshot = render

    expect(snapshot).to match(/no persisted reconciliation/i)
    expect(snapshot).to match(/coverage limitation|unresolved coverage/i)
    expect(snapshot).not_to match(/no (traceability )?gaps exist/i)
  end
end
