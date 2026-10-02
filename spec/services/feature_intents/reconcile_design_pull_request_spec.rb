# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-016
RSpec.describe FeatureIntents::ReconcileDesignPullRequest do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, :approved_waiting_for_merge, project: project) }
  let(:head_sha) { "a" * 40 }
  let(:design_pr) { create(:feature_intent_design_pr, feature_intent: feature, head_sha: head_sha) }
  let(:head) { Data.define(:sha).new(head_sha) }
  let(:pull_request_class) { Data.define(:head, :merged_at, :merge_commit_sha) }
  let(:github_issue_class) { Data.define(:number, :state, :pull_request) }

  it "releases a previously approved feature only after the synced merge" do
    feature.update!(approved_pr_heads: { design_pr.pull_request_number.to_s => head_sha })
    github_issue = github_issue_class.new(design_pr.pull_request_number, "closed",
      pull_request_class.new(head, Time.current, "c" * 40))

    described_class.call(project: project, github_issue: github_issue)

    expect(feature.reload).to be_released
    expect(feature.approved_design_revision).to eq("c" * 40)
  end

  it "returns an abandoned design PR to design review without releasing it" do
    github_issue = github_issue_class.new(design_pr.pull_request_number, "closed",
      pull_request_class.new(head, nil, nil))

    described_class.call(project: project, github_issue: github_issue)

    expect(feature.reload.status).to eq("design_open")
    expect(feature.approved_at).to be_nil
  end
end
