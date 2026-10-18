# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::ReconcileDesignArtifacts do
  let(:project) { create(:project, owner: "acme", repo: "widget") }
  let(:issues) do
    [
      { repository: "acme/widget", number: 10, state: "open", revision: "2026-10-16T00:00:00Z" },
      { repository: "shared/platform", number: 11, state: "closed" }
    ]
  end

  it "recognizes explicit qualified cross-repository links as an existing tree" do
    result = described_class.call(
      project:,
      revision: "a" * 40,
      artifacts: [ { path: "docs/rdrs/RDR-100.md", related_issues: [ "acme/widget#10", "shared/platform#11" ] } ],
      issues:
    )

    expect(result.findings).to be_empty
    expect(result.last_successful_coverage_at).to be_present
  end

  it "resolves an unambiguous local association while retaining its provenance" do
    result = described_class.call(
      project:,
      revision: "a" * 40,
      artifacts: [ {
        path: "docs/rdrs/RDR-100.md",
        related_issues: [],
        associated_issues: [ { repository: "acme/widget", number: 10, provenance: "explicit artifact backlink" } ]
      } ],
      issues:
    )

    expect(result.findings).to be_empty
    expect(result.associations).to contain_exactly(
      include(path: "docs/rdrs/RDR-100.md", identity: "acme/widget#10", provenance: "explicit artifact backlink")
    )
  end

  it "assesses semantic candidates before escalating an unlinked artifact" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    response = instance_double(AgentHarness::Response, success?: true, output: '{"issue_identity":"acme/widget#10","explanation":"Candidate implements the RDR scope"}')
    allow(AgentHarness).to receive(:send_message).and_return(response)

    result = described_class.call(
      project:, revision: "a" * 40,
      artifacts: [ { path: "docs/rdrs/RDR-100.md", body: "Traceability requirements" } ],
      issues:
    )

    expect(result.findings).to be_empty
    expect(result.associations).to contain_exactly(
      include(
        identity: "acme/widget#10", issue_revision: "2026-10-16T00:00:00Z",
        provenance: "semantic candidate assessment: Candidate implements the RDR scope"
      )
    )
  end

  it "treats an explicitly historical decision as deliberately deferred" do
    result = described_class.call(
      project:,
      revision: "a" * 40,
      artifacts: [ { path: "docs/rdrs/RDR-099.md", status: "Historical" } ],
      issues:
    )

    expect(result.findings.sole).to have_attributes(state: "deferred")
  end

  it "does not convert failed GitHub coverage into a missing-tree finding" do
    result = described_class.call(
      project:,
      revision: "a" * 40,
      artifacts: [ { path: "docs/rdrs/RDR-063.md", related_issues: [] } ],
      issues: [],
      coverage_complete: false
    )

    expect(result.findings.first.state).to eq("unverifiable")
    expect(result.findings.first.evidence).to include("GitHub coverage was incomplete")
  end

  it "keeps deliberately deferred and draft artifacts out of missing-tree findings" do
    result = described_class.call(
      project:,
      revision: "a" * 40,
      artifacts: [
        { path: "docs/rdrs/RDR-101.md", status: "Draft" },
        { path: "docs/rdrs/RDR-102.md", status: "Deferred" }
      ],
      issues:
    )

    expect(result.findings.map(&:state)).to all(eq("deferred"))
  end

  it "distinguishes a partial explicit tree from stale local metadata" do
    result = described_class.call(
      project:,
      revision: "a" * 40,
      artifacts: [
        { path: "docs/rdrs/RDR-103.md", related_issues: [ "acme/widget#10", "acme/widget#99" ] },
        { path: "docs/rdrs/RDR-104.md", related_issues: [], stored_identities: [ "acme/widget#10" ] }
      ],
      issues:
    )

    expect(result.findings.map(&:state)).to contain_exactly("partial_tree", "stale_metadata")
  end

  it "retains an unknown stored identity as stale metadata evidence" do
    result = described_class.call(
      project:,
      revision: "a" * 40,
      artifacts: [ { path: "docs/rdrs/RDR-105.md", related_issues: [], stored_identities: [ "acme/widget#99" ] } ],
      issues:
    )

    finding = result.findings.sole
    expect(finding.state).to eq("stale_metadata")
    expect(finding.evidence).to include("Stored identity acme/widget#99 could not be found in GitHub coverage")
  end
end
