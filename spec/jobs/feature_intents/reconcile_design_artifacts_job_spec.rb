# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::ReconcileDesignArtifactsJob do
  let(:project) { create(:project, owner: "acme", repo: "widget") }
  let(:feature_intent) { create(:feature_intent, project:) }
  let(:design_pr) { create(:feature_intent_design_pr, feature_intent:, pull_request_number: 100) }

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
