# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-012 @spec FEATURE-APPROVAL-025
RSpec.describe FeatureIntents::ReconcileDesignPullRequest do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, :approved_waiting_for_merge, project: project) }
  let(:head_sha) { "a" * 40 }
  let(:design_pr) { create(:feature_intent_design_pr, feature_intent: feature, head_sha: head_sha) }
  let(:head) { Data.define(:sha).new(head_sha) }
  let(:pull_request_class) { Data.define(:head, :merged_at, :merge_commit_sha, :merged_by) }
  let(:github_issue_class) { Data.define(:number, :state, :pull_request) }

  it "releases a previously approved feature only after the synced merge" do
    feature.update!(approved_pr_heads: { design_pr.pull_request_number.to_s => head_sha })
    github_issue = github_issue_class.new(design_pr.pull_request_number, "closed",
      pull_request_class.new(head, Time.current, "c" * 40, nil))

    described_class.call(project: project, github_issue: github_issue)

    expect(feature.reload).to be_released
    expect(feature.approved_design_revision).to eq("c" * 40)
  end

  it "returns an abandoned design PR to design review without releasing it" do
    github_issue = github_issue_class.new(design_pr.pull_request_number, "closed",
      pull_request_class.new(head, nil, nil, nil))

    described_class.call(project: project, github_issue: github_issue)

    expect(feature.reload.status).to eq("design_open")
    expect(feature.approved_at).to be_nil
  end

  it "records and releases an authorized direct human merge" do
    feature.update!(status: "ready_for_approval")
    design_pr.update!(reviewed_head_sha: head_sha)
    actor = create(:user, :member, account: project.account)
    token = create(:github_token, account: project.account, created_by: actor)
    merger = Data.define(:login, :type).new("authorized-merger", "User")
    github_issue = github_issue_class.new(design_pr.pull_request_number, "closed",
      pull_request_class.new(head, Time.current, "c" * 40, merger))

    described_class.call(
      project: project,
      github_issue: github_issue,
      authenticated_login_resolver: ->(account_token) { "authorized-merger" if account_token == token }
    )

    expect(feature.reload).to be_released
    expect(feature.approved_by).to eq(actor)
    expect(feature.approved_design_revision).to eq("c" * 40)
  end

  it "keeps a bot direct merge held without a prior human approval" do
    feature.update!(status: "ready_for_approval", approved_by: nil, approved_at: nil)
    design_pr.update!(reviewed_head_sha: head_sha)
    merger = Data.define(:login, :type).new("paid-agents[bot]", "Bot")
    github_issue = github_issue_class.new(design_pr.pull_request_number, "closed",
      pull_request_class.new(head, Time.current, "c" * 40, merger))

    described_class.call(project: project, github_issue: github_issue)

    expect(feature.reload.status).to eq("ready_for_approval")
    expect(feature.approved_by).to be_nil
  end

  it "keeps an incomplete direct human merge held" do
    feature.update!(status: "ready_for_approval", approved_by: nil, approved_at: nil)
    design_pr.update!(reviewed_head_sha: head_sha)
    create(:feature_intent_design_pr, feature_intent: feature, pull_request_number: 99,
      head_sha: "b" * 40, reviewed_head_sha: "b" * 40)
    merger = Data.define(:login, :type).new("authorized-merger", "User")
    github_issue = github_issue_class.new(design_pr.pull_request_number, "closed",
      pull_request_class.new(head, Time.current, "c" * 40, merger))

    described_class.call(project: project, github_issue: github_issue)

    expect(feature.reload.status).to eq("ready_for_approval")
    expect(feature.approved_by).to be_nil
  end
end
