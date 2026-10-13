# frozen_string_literal: true

require "rails_helper"

# @spec ISSUE-TREE-001 @spec ISSUE-TREE-002 @spec ISSUE-TREE-003
RSpec.describe FeatureIntents::IssueTreeReceipt do
  let(:project) { create(:project) }
  let(:feature_intent) { create(:feature_intent, project: project) }
  let(:first_issue) { create(:issue, project: project, github_number: 101) }
  let(:second_issue) { create(:issue, project: project, github_number: 102) }
  let(:tasks) do
    [
      { identity: "foundation", index: 0, title: "Foundation", dependencies: [] },
      { identity: "delivery", index: 1, title: "Delivery", dependencies: [ "foundation" ] }
    ]
  end
  let(:created_issues) do
    [
      { identity: "foundation", index: 0, github_number: 101, issue_id: first_issue.id, issue_url: "https://github.test/issues/101" },
      { identity: "delivery", index: 1, github_number: 102, issue_id: second_issue.id, issue_url: "https://github.test/issues/102" }
    ]
  end

  it "persists qualified stable task identities and links every confirmed issue before success" do
    result = described_class.record(
      feature_intent:, tasks:, created_issues:, plan_revision: "design-sha"
    )

    expect(result).to be_complete
    expect(feature_intent.reload.issue_tree_manifest).to include("revision" => "design-sha")
    expect(feature_intent.issue_tree_manifest.fetch("tasks").map { |task| task.fetch("identity") }).to eq(%w[foundation delivery])
    expect(feature_intent.issues).to include(first_issue, second_issue)
    expect(feature_intent.issue_tree_verification).to include("state" => "verified")
  end

  it "retains the confirmed issue and reports the remaining task after partial filing" do
    result = described_class.record(
      feature_intent:, tasks:, created_issues: created_issues.first(1), plan_revision: "design-sha"
    )

    expect(result).not_to be_complete
    expect(result.unresolved).to include("missing issue for delivery")
    expect(feature_intent.issues).to include(first_issue)
  end

  it "rejects a verification made for a changed plan revision" do
    described_class.record(feature_intent:, tasks:, created_issues:, plan_revision: "old-sha")

    result = described_class.verify(feature_intent:, plan_revision: "new-sha")

    expect(result.state).to eq("stale")
    expect(result).not_to be_complete
  end

  it "reports unknown remote access separately from confirmed absence" do
    client = instance_double(GithubClient)
    allow(client).to receive(:issue).and_raise(GithubClient::Error, "forbidden")

    result = described_class.record(feature_intent:, tasks:, created_issues:, plan_revision: "design-sha", client: client)

    expect(result.unresolved).to include("remote access unknown for foundation", "remote access unknown for delivery")
  end

  it "blocks completion while the native parent link remains unreconciled" do
    result = described_class.record(
      feature_intent:, tasks:, created_issues:,
      plan_revision: "design-sha", parent_issue_number: 451,
      parent_issue_updated: false
    )

    expect(result).not_to be_complete
    expect(result.state).to eq("incomplete")
    expect(result.missing_native_links).to include(
      a_string_matching(/native parent link unavailable/)
    )
    expect(result.unresolved).to include(
      a_string_matching(/native parent link unavailable/)
    )
    expect(feature_intent.reload.issue_tree_verification.fetch("state")).to eq("incomplete")
  end

  it "treats a successfully updated parent as reconciled and does not flag the native link" do
    result = described_class.record(
      feature_intent:, tasks:, created_issues:,
      plan_revision: "design-sha", parent_issue_number: 451,
      parent_issue_updated: true
    )

    expect(result).to be_complete
    expect(result.state).to eq("verified")
    expect(result.missing_native_links).to be_empty
    expect(result.unresolved).to be_empty
    expect(feature_intent.reload.issue_tree_verification.fetch("state")).to eq("verified")
  end
end
