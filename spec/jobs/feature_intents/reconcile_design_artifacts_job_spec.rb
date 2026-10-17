# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::ReconcileDesignArtifactsJob do
  let(:project) { create(:project, owner: "acme", repo: "widget") }
  let(:feature_intent) { create(:feature_intent, project:) }
  let(:design_pr) { create(:feature_intent_design_pr, feature_intent:, pull_request_number: 100, draft: false) }

  before do
    response = instance_double(AgentHarness::Response, success?: false, output: nil)
    allow(AgentHarness).to receive(:send_message).and_return(response)
  end

  it "persists an actionable finding from a synced design pull request" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "missing_tree", status: "open"
    )
  end

  it "does not treat a synced draft design pull request without links as missing" do
    design_pr.update!(draft: true)
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "deferred", status: "open"
    )
  end

  it "treats an unknown draft state as unverifiable until synchronization" do
    design_pr.update!(draft: nil)
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "unverifiable", status: "open"
    )
  end

  it "treats a design pull request missing from the local issue mirror as unverifiable" do
    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "unverifiable", status: "open"
    )
  end

  it "does not treat draft, deferred, or superseded RDRs without links as missing" do
    [ "Draft", "Deferred", "Superseded" ].each do |status|
      artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
        path: "docs/rdrs/RDR-#{status.downcase}.md",
        revision: status.downcase,
        body: "Status: #{status}"
      )
      allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([ artifact ])

      described_class.perform_now(project.id)

      expect(DesignArtifactFinding.find_by!(artifact_path: artifact.path)).to have_attributes(
        state: "deferred", status: "open"
      )
    end
  end

  it "uses explicit linked issue references to clear the finding" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "**Implements:** #101")
    create(:issue, project:, github_number: 101)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
  end

  it "uses a stored Paid feature-intent link without requiring a document repair" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")
    linked_issue = create(:issue, project:, github_number: 101)
    create(:feature_intent_issue, feature_intent:, issue: linked_issue)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole.provenance).to eq("Paid feature intent linkage")
  end

  it "assesses synchronized open issue candidates before creating a missing-tree finding" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    response = instance_double(AgentHarness::Response, success?: true,
      output: '{"issue_identity":"acme/widget#101","explanation":"It implements this design."}')
    allow(AgentHarness).to receive(:send_message).and_return(response)
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "No issue tree yet")
    create(:issue, project:, github_number: 101, title: "Implement design", body: "Implementation work")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole).to have_attributes(issue_identity: "acme/widget#101")
  end

  it "uses issue links listed under an RDR relationship heading" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "### Related Issues\n\n- #216\n"
    )
    create(:issue, project:, github_number: 216)
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([ artifact ])

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
  end

  it "uses an exact issue backlink to reconcile an RDR without repairing the document" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    create(:issue, project:, github_number: 216,
      body: "Implements docs/rdrs/RDR-020-service-container-architecture.md")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([ artifact ])

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.count).to eq(0)
    expect(DesignArtifactAssociation.sole).to have_attributes(
      artifact_path: artifact.path, artifact_revision: artifact.revision,
      issue_identity: "acme/widget#216", provenance: "exact artifact backlink"
    )
  end

  it "does not use an exact backlink from another repository in the account" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    other_project = create(:project, account: project.account, owner: "acme", repo: "other-widget")
    create(:issue, project: other_project, github_number: 216,
      body: "Implements docs/rdrs/RDR-020-service-container-architecture.md")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([ artifact ])

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: artifact.path, revision: artifact.revision, state: "missing_tree", status: "open"
    )
    expect(DesignArtifactAssociation.count).to eq(0)
  end

  it "does not treat an untrusted issue backlink as structural evidence" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    create(:issue, project:, github_number: 216, github_creator_login: "attacker",
      body: "Implements docs/rdrs/RDR-020-service-container-architecture.md")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([ artifact ])

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: artifact.path, revision: artifact.revision, state: "missing_tree", status: "open"
    )
    expect(DesignArtifactAssociation.count).to eq(0)
  end

  it "does not treat an incidental artifact-path mention as an artifact backlink" do
    artifact = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(
      path: "docs/rdrs/RDR-020-service-container-architecture.md",
      revision: "a" * 40,
      body: "Status: Accepted"
    )
    create(:issue, project:, github_number: 216,
      body: "We discussed `docs/rdrs/RDR-020-service-container-architecture.md` last week.")
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([ artifact ])

    described_class.perform_now(project.id)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: artifact.path, revision: artifact.revision, state: "missing_tree", status: "open"
    )
    expect(DesignArtifactAssociation.count).to eq(0)
  end

  it "does not treat an incidental issue mention as an issue-tree relationship" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number,
      body: "The prior discussion in #101 explains why this was deferred.")
    create(:issue, project:, github_number: 101)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(
      artifact_path: "pull/100", revision: design_pr.head_sha, state: "missing_tree", status: "open"
    )
  end

  it "treats an unmirrored cross-repository reference as unverifiable" do
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "Implements shared/platform#11")

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.sole).to have_attributes(state: "unverifiable", artifact_path: "pull/100")
  end

  it "includes a locally mirrored cross-repository issue in coverage" do
    shared_project = create(:project, account: project.account, owner: "shared", repo: "platform")
    create(:issue, :pull_request, project:, github_number: design_pr.pull_request_number, body: "Implements shared/platform#11")
    create(:issue, project: shared_project, github_number: 11)

    described_class.perform_now(project.id, design_pr.pull_request_number)

    expect(DesignArtifactFinding.count).to eq(0)
  end

  it "resolves RDR findings removed from a successfully discovered directory" do
    finding = create(:design_artifact_finding, project:, account: project.account,
      artifact_path: "docs/rdrs/RDR-063-removed.md", revision: "a" * 40)
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([])

    described_class.perform_now(project.id)

    expect(finding.reload.status).to eq("resolved")
  end

  it "keeps RDR findings open when directory discovery is unverifiable" do
    finding = create(:design_artifact_finding, project:, account: project.account,
      artifact_path: "docs/rdrs/RDR-063-unknown.md", revision: "a" * 40)
    unavailable = FeatureIntents::DiscoverRdrArtifacts::Artifact.new(path: "docs/rdrs", revision: "main", body: nil)
    allow(FeatureIntents::DiscoverRdrArtifacts).to receive(:call).with(project:).and_return([ unavailable ])

    described_class.perform_now(project.id)

    expect(finding.reload.status).to eq("open")
  end
end
