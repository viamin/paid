# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-004 @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-009
# @spec AUTOMATION-PHASES-010 @spec AUTOMATION-PHASES-011
RSpec.describe "Project agent run continuation" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }

  before do
    sign_in user
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  it "creates a run and continuation grant from the rendered form signature" do
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_authorized: "1",
        continuation_endpoint: "merge",
        continuation_notice_signature: signature
      }
    }.to change(AgentRun, :count).by(1)
      .and change(WorkItemContinuationGrant, :count).by(1)

    expect(response).to redirect_to(project_path(project))
    expect(WorkItemContinuationGrant.last).to have_attributes(
      issue:, start_phase: "coding", endpoint: "merge", created_by: user
    )
  end

  it "offers the create_feature manual start its discovery continuation plan" do
    get new_project_agent_run_path(project, goal: "create_feature")

    expect(response.body).to include("continuation_authorized")
    expect(response.body).to include("continuation_endpoint")
    expect(response.body).to include("You selected automation through Issue preparation.")
  end

  it "carries a selected create_feature continuation onto the work item the run creates" do
    stub_create_feature_github!
    get new_project_agent_run_path(project, goal: "create_feature")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_feature",
        feature_description: "Add a dark mode toggle.",
        continuation_authorized: "1",
        continuation_endpoint: "coding",
        continuation_notice_signature: signature
      }
    }.to change(AgentRun, :count).by(1)
      .and change(WorkItemContinuationGrant, :count).by(1)

    expect(WorkItemContinuationGrant.last).to have_attributes(
      issue: AgentRun.last.issue, start_phase: "discovery", endpoint: "coding", created_by: user
    )
  end

  it "embeds a per-goal continuation plan so the form refreshes on goal changes" do
    get new_project_agent_run_path(project, goal: "create_pr")

    plans = rendered_continuation_plans
    expect(plans.keys).to contain_exactly("create_pr", "create_issue", "review", "enhance_issue", "create_feature")
    expect(plans.fetch("create_pr")).to include(
      "default_endpoint" => "coding",
      "endpoints" => [ { "value" => "coding", "label" => "Coding" }, { "value" => "merge", "label" => "Merge" } ]
    )
    expect(plans.fetch("enhance_issue")["default_endpoint"]).to eq("issue_preparation")
    expect(plans.fetch("create_feature")["default_endpoint"]).to eq("issue_preparation")
    expect(plans.dig("create_pr", "notices", "merge")).to include("You selected automation through Merge")
  end

  it "renders the default plan when GET continuation parameters are invalid" do
    get new_project_agent_run_path(project, goal: "create_pr", continuation_endpoint: "discovery")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("continuation_endpoint")
  end

  it "renders the default plan when GET continuation delegation is unauthorized" do
    sign_in create(:user, :member, account:)

    get new_project_agent_run_path(project, goal: "create_pr", continuation_authorized: "1", continuation_endpoint: "merge")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("continuation_endpoint")
  end

  it "rejects continuation when the run has no work item to authorize" do
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        custom_prompt: "Implement the requested change",
        continuation_authorized: "1",
        continuation_endpoint: "merge",
        continuation_notice_signature: signature
      }
    }.not_to change(AgentRun, :count)

    expect(WorkItemContinuationGrant.count).to eq(0)
    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    expect(flash[:alert]).to eq("Select an issue or pull request to authorize automatic continuation.")
  end

  it "returns an invalid endpoint to the form without creating a run" do
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_authorized: "1",
        continuation_endpoint: "issue_preparation",
        continuation_notice_signature: signature
      }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    expect(flash[:alert]).to eq("Choose a continuation endpoint offered for this action.")
  end

  it "returns unauthorized merge delegation to the form without creating a run" do
    member = create(:user, :member, account:)
    sign_in member
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_authorized: "1",
        continuation_endpoint: "merge",
        continuation_notice_signature: signature
      }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    expect(flash[:alert]).to eq("You do not have permission to delegate merging for this project.")
  end

  it "returns a changed project policy to the form for review" do
    get new_project_agent_run_path(project, goal: "create_pr")
    signature = rendered_signature
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => true },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )

    expect {
      post project_agent_runs_path(project), params: {
        goal: "create_pr",
        issue_id: issue.id,
        continuation_notice_signature: signature
      }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    expect(flash[:alert]).to include("automation settings changed")
  end

  it "routes an issue quick start through the reviewed continuation form" do # @spec AUTOMATION-PHASES-010
    expect {
      post quick_create_project_agent_runs_path(project), params: { issue_id: issue.id }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr", issue_id: issue.id))
  end

  it "shows effective authority and the active grant on work details" do # @spec AUTOMATION-PHASES-008 @spec AUTOMATION-PHASES-010
    run = create(:agent_run, project:, issue:, goal: "create_pr")
    create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

    get project_agent_run_path(project, run)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Automation authority", "Continuation grant:", "project defaults may independently permit this work.")
  end

  def rendered_signature
    Nokogiri::HTML(response.body)
      .at_css("input[name='continuation_notice_signature']")["value"]
  end

  def rendered_continuation_plans
    form = Nokogiri::HTML(response.body)
      .at_css("form[data-goal-toggle-continuation-plans-value]")

    JSON.parse(form["data-goal-toggle-continuation-plans-value"])
  end

  def stub_create_feature_github!
    github_client = instance_double(GithubClient)
    gh_issue = Struct.new(:number, :html_url, :id, :title, :body, :state, :user, :labels, :created_at, :updated_at).new(
      4321,
      "https://github.com/example/repo/issues/4321",
      1,
      "[Feature] Add a dark mode toggle.",
      "Add a dark mode toggle.",
      "open",
      Struct.new(:login).new("paid-agents"),
      [],
      Time.current,
      Time.current
    )
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue).and_return(gh_issue)
    allow(ProcessRunQueueJob).to receive(:perform_later)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])
  end
end
