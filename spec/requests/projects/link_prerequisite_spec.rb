# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Link prerequisite from the partial closeout pane" do # @spec PARTIAL-CLOSEOUT-016
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account, created_by: user) }
  let(:project) do
    create(:project, account: account, github_token: github_token, created_by: user,
      owner: "acme", repo: "alpha", auto_pick_enabled: true, active: true)
  end
  let(:issue) { create(:issue, project: project, github_number: 40, paid_state: "in_progress", body: "Original body.") }
  let!(:prerequisite) { create(:issue, project: project, github_number: 41, github_state: "open") }
  let(:merged_pr) do
    create(:issue, :pull_request, project: project, github_number: 42, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id, created_at: 2.days.ago)
  end
  let(:remote_issue) { Struct.new(:body).new("Original body.") }
  let(:github_client) do
    instance_double(GithubClient,
      issue: remote_issue,
      update_issue: true,
      recent_issue_comments: [])
  end

  before do
    merged_pr
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  it "redirects when not authenticated" do
    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#41" }

    expect(response).to redirect_to(new_user_session_path)
    expect(IssueDependency.count).to eq(0)
  end

  it "does not leak cross-tenant projects" do
    sign_in create(:user)

    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#41" }

    expect(response).to have_http_status(:not_found)
    expect(IssueDependency.count).to eq(0)
  end

  it "refuses a viewer without run permission" do
    sign_in create(:user, account: account)

    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#41" }

    expect(response).not_to have_http_status(:ok)
    expect(IssueDependency.count).to eq(0)
  end

  it "appends the dependency wording on GitHub and links the prerequisite locally without a sync" do
    sign_in user

    expect {
      post link_prerequisite_project_agent_runs_path(project),
        params: { issue_id: issue.id, depends_on: "#41", return_to: inbox_path(kind: :partial_closeout) }
    }.to change { issue.reload.issue_dependencies.count }.by(1)

    expect(github_client).to have_received(:update_issue)
      .with(project.full_name, issue.github_number, body: a_string_including("Depends on #41"))
    expect(issue.reload.body).to include("Depends on #41")
    expect(issue.issue_dependencies.last.depends_on_issue_id).to eq(prerequisite.id)
    expect(account.account_activity_events.where(action: "issue.prerequisite_linked")).to exist
    expect(response).to redirect_to(inbox_path(kind: :partial_closeout))
    expect(flash[:notice]).to include("#41").and include("sync")
  end

  it "refuses a self-referential prerequisite" do
    sign_in user

    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#40" }

    expect(flash[:alert]).to include("cannot depend on itself")
    expect(issue.reload.issue_dependencies.count).to eq(0)
    expect(github_client).not_to have_received(:update_issue)
  end

  it "refuses a prerequisite Paid has not synced yet and explains the sync requirement" do
    sign_in user

    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#999" }

    expect(flash[:alert]).to include("sync")
    expect(issue.reload.issue_dependencies.count).to eq(0)
    expect(github_client).not_to have_received(:update_issue)
  end

  it "refuses a prerequisite that already depends on the stalled issue" do
    sign_in user
    IssueDependency.create!(issue: prerequisite, depends_on_issue: issue)

    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#41" }

    expect(flash[:alert]).to include("already depends on this issue")
    expect(issue.reload.body).to eq("Original body.")
    expect(issue.issue_dependencies).to be_empty
    expect(github_client).not_to have_received(:issue)
    expect(github_client).not_to have_received(:update_issue)
    expect(account.account_activity_events.where(action: "issue.prerequisite_linked")).not_to exist
  end

  it "explains when GitHub access is unavailable" do
    sign_in user
    installation = create(:github_installation, :revoked, account: account)
    project.update_columns(github_token_id: nil, github_installation_id: installation.id)

    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#41" }

    expect(flash[:alert]).to include("GitHub access is not configured")
    expect(issue.reload.body).to eq("Original body.")
    expect(issue.issue_dependencies).to be_empty
  end

  it "is idempotent when the wording is already on the issue" do
    sign_in user
    remote_issue.body = "## Dependencies\n- Depends on #41"

    expect {
      post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "#41" }
    }.to change { issue.reload.issue_dependencies.count }.by(1)

    expect(github_client).not_to have_received(:update_issue)
    expect(flash[:notice]).to include("#41")
  end

  it "refuses malformed input" do
    sign_in user

    post link_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id, depends_on: "not-a-ref" }

    expect(flash[:alert]).to be_present
    expect(issue.reload.issue_dependencies.count).to eq(0)
    expect(github_client).not_to have_received(:update_issue)
  end
end
