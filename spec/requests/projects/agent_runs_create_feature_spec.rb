# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-014
RSpec.describe "POST /projects/:project_id/agent_runs (create_feature)" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:github_token) { create(:github_token, account: account, created_by: owner) }
  let(:project) { create(:project, account: account, github_token: github_token, created_by: owner) }
  let(:github_client) { instance_double(GithubClient) }
  let(:gh_issue) do
    Struct.new(:number, :html_url, :id, :title, :body, :state, :user, :labels, :created_at, :updated_at).new(
      1234,
      "https://github.com/example/repo/issues/1234",
      1,
      "[Feature] Add dark mode",
      "Add dark mode toggle in user settings",
      "open",
      Struct.new(:login).new("paid-agents"),
      [],
      Time.current,
      Time.current
    )
  end

  before do
    sign_in owner
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue).and_return(gh_issue)
    allow(ProcessRunQueueJob).to receive(:perform_later)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])
  end

  it "creates a FeatureIntent in the discovering state and links the brief issue" do
    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_feature",
        feature_description: "Add dark mode toggle in user settings"
      }
    }.to change(FeatureIntent, :count).by(1)

    feature_intent = FeatureIntent.last
    expect(feature_intent.status).to eq("discovering")
    expect(feature_intent.criteria_clarity_state).to eq("pending")
    expect(feature_intent.project).to eq(project)
    expect(feature_intent.brief).to include("Add dark mode")
    expect(feature_intent.issues).not_to be_empty
  end

  it "reuses the FeatureIntent when the same run is attached again" do
    # A fresh HTTP POST files a fresh brief issue and therefore a fresh
    # FeatureIntent; reuse is keyed on the brief-issue link, so it is
    # exercised here by re-running the attachment for the same run.
    post project_agent_runs_path(project), params: {
      goal: "create_feature",
      feature_description: "Add dark mode"
    }
    feature_intent = FeatureIntent.last
    agent_run = AgentRun.where(goal: "create_feature").last

    result = nil
    expect {
      result = FeatureIntents::AttachFromAgentRun.call(
        agent_run: agent_run,
        goal: "create_feature",
        brief: { "title" => "Add dark mode" }
      )
    }.not_to change(FeatureIntent, :count)

    expect(result.feature_intent).to eq(feature_intent)
  end
end
