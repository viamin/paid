# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "Projects" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:empty_screenshot_repo_config_result) do
    Projects::Screenshots::RepoConfig::Result.new(config: {}, content: nil, error: nil)
  end

  def screenshot_repo_config_result(config: {}, content: nil, error: nil)
    Projects::Screenshots::RepoConfig::Result.new(config: config, content: content, error: error)
  end

  describe "GET /projects" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get projects_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get projects_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Projects")
      end

      it "shows the user's projects" do
        create(:project, account: account, github_token: github_token, name: "My Project")
        get projects_path
        expect(response.body).to include("My Project")
      end

      it "does not show projects from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        create(:project, account: other_account, github_token: other_token, name: "Other Project")
        get projects_path
        expect(response.body).not_to include("Other Project")
      end

      it "shows status indicators for active projects" do
        create(:project, account: account, github_token: github_token)
        get projects_path
        expect(response.body).to include("Active")
      end

      it "shows status indicators for inactive projects" do
        create(:project, :inactive, account: account, github_token: github_token)
        get projects_path
        expect(response.body).to include("Inactive")
      end

      it "displays project metrics" do
        project = create(:project, :with_metrics, account: account, github_token: github_token)
        create_list(:agent_run, 3, project: project)
        get projects_path
        expect(response.body).to include(">3</span> runs")
        expect(response.body).to include("$15.00")
      end

      it "shows sort controls" do
        create(:project, account: account, github_token: github_token)
        get projects_path
        expect(response.body).to include("Sort by:")
        expect(response.body).to include("Paid Activity")
        expect(response.body).to include("GitHub Activity")
        expect(response.body).to include("Name")
      end

      it "shows auto-pick toggle on project cards" do
        create(:project, account: account, github_token: github_token, auto_pick_enabled: false)
        get projects_path
        expect(response.body).to include("Auto-Pick")
        expect(response.body).to include("bg-gray-100 text-gray-600")
      end

      it "shows auto-pick enabled state on project cards" do
        create(:project, account: account, github_token: github_token, auto_pick_enabled: true)
        get projects_path
        expect(response.body).to include("Auto-Pick")
        expect(response.body).to include("bg-green-100 text-green-700")
      end

      it "shows auto-pick status but no toggle controls for viewers" do
        viewer_user = create(:user, :viewer, account: account)
        project = create(:project, account: account, github_token: github_token, auto_pick_enabled: true)

        sign_out user
        sign_in viewer_user

        get projects_path

        expect(response.body).to include("Auto-Pick")
        expect(response.body).to include("bg-green-100 text-green-700")
        expect(response.body).not_to include(toggle_auto_pick_project_path(project))
      end

      it "shows auto-merge toggle on project cards" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "off")
        get projects_path
        expect(response.body).to match(/Auto-Merge[\s\S]*?bg-gray-100 text-gray-600/)
        expect(response.body).to include(toggle_auto_merge_project_path(project))
      end

      it "shows auto-merge enabled state on project cards" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "all")
        get projects_path
        expect(response.body).to match(/Auto-Merge[\s\S]*?bg-green-100 text-green-700/)
        expect(response.body).to include(toggle_auto_merge_project_path(project))
      end

      it "shows auto-merge status but no toggle controls for viewers" do
        viewer_user = create(:user, :viewer, account: account)
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "all")

        sign_out user
        sign_in viewer_user

        get projects_path

        expect(response.body).to match(/Auto-Merge[\s\S]*?bg-green-100 text-green-700/)
        expect(response.body).not_to include(toggle_auto_merge_project_path(project))
      end

      it "sorts projects by name ascending via Ransack sort params" do
        create(:project, account: account, github_token: github_token, name: "Zebra")
        create(:project, account: account, github_token: github_token, name: "Alpha")

        get projects_path, params: { q: { s: "name asc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index("Alpha")).to be < response.body.index("Zebra")
      end

      it "sorts projects by name descending via Ransack sort params" do
        create(:project, account: account, github_token: github_token, name: "Alpha")
        create(:project, account: account, github_token: github_token, name: "Zebra")

        get projects_path, params: { q: { s: "name desc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index("Zebra")).to be < response.body.index("Alpha")
      end

      it "sorts projects by last_agent_run_at via Ransack sort params" do
        old_project = create(:project, account: account, github_token: github_token, name: "Old Project", last_agent_run_at: 2.days.ago)
        new_project = create(:project, account: account, github_token: github_token, name: "New Project", last_agent_run_at: 1.hour.ago)

        get projects_path, params: { q: { s: "last_agent_run_at desc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(new_project.name)).to be < response.body.index(old_project.name)
      end

      it "sorts projects by last_github_activity_at via Ransack sort params" do
        old_project = create(:project, account: account, github_token: github_token, name: "Old GH Project", last_github_activity_at: 3.days.ago)
        new_project = create(:project, account: account, github_token: github_token, name: "New GH Project", last_github_activity_at: 1.hour.ago)

        get projects_path, params: { q: { s: "last_github_activity_at desc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(new_project.name)).to be < response.body.index(old_project.name)
      end

      it "sorts projects with NULL last_agent_run_at to the end in descending order" do
        null_project = create(:project, account: account, github_token: github_token, name: "No Activity", last_agent_run_at: nil)
        active_project = create(:project, account: account, github_token: github_token, name: "Has Activity", last_agent_run_at: 1.hour.ago)

        get projects_path, params: { q: { s: "last_agent_run_at desc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(active_project.name)).to be < response.body.index(null_project.name)
      end

      it "sorts projects with NULL last_github_activity_at to the end in ascending order" do
        null_project = create(:project, account: account, github_token: github_token, name: "No GH Activity", last_github_activity_at: nil)
        active_project = create(:project, account: account, github_token: github_token, name: "Has GH Activity", last_github_activity_at: 1.hour.ago)

        get projects_path, params: { q: { s: "last_github_activity_at asc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(active_project.name)).to be < response.body.index(null_project.name)
      end

      it "defaults to last_agent_run_at desc when no sort is specified" do
        old_project = create(:project, account: account, github_token: github_token, name: "Older Project", last_agent_run_at: 2.days.ago)
        new_project = create(:project, account: account, github_token: github_token, name: "Newer Project", last_agent_run_at: 1.hour.ago)

        get projects_path

        expect(response).to have_http_status(:ok)
        expect(response.body.index(new_project.name)).to be < response.body.index(old_project.name)
      end
    end
  end

  describe "merge notification subscriptions" do
    let(:project) { create(:project, account: account, github_token: github_token) }
    let(:issue) { create(:issue, project: project, github_number: 14, title: "Fix flaky spec") }
    let(:pull_request) { create(:issue, :pull_request, project: project, github_number: 28, title: "Improve CI") }

    before { sign_in user }

    it "shows subscribe controls for issues and pull requests" do
      issue
      pull_request

      get project_path(project)

      expect(response.body).to include("Notify on completion")
      expect(response.body).to include("Notify on merge")
    end

    it "creates a subscription and redirects back to the project anchor" do
      post project_issue_merge_subscription_path(project, issue)

      expect(response).to redirect_to(project_path(project, anchor: ActionView::RecordIdentifier.dom_id(issue)))
      expect(user.issue_merge_subscriptions.on_merge.find_by(issue: issue)).to be_present
    end

    it "shows the unsubscribe control for subscribed issues" do
      create(:issue_merge_subscription, issue: issue, user: user)

      get project_path(project)

      expect(response.body).to include("Stop completion alerts")
    end

    it "renders the current subscription state for turbo-frame refreshes" do
      create(:issue_merge_subscription, issue: issue, user: user)

      get project_issue_merge_subscription_path(project, issue)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Stop completion alerts")
    end

    it "removes a subscription" do
      create(:issue_merge_subscription, issue: issue, user: user)

      delete project_issue_merge_subscription_path(project, issue)

      expect(response).to redirect_to(project_path(project, anchor: ActionView::RecordIdentifier.dom_id(issue)))
      expect(user.issue_merge_subscriptions.on_merge.find_by(issue: issue)).to be_nil
    end

    it "does not allow users from another account to subscribe" do
      other_user = create(:user)
      sign_out user
      sign_in other_user

      expect {
        post project_issue_merge_subscription_path(project, issue)
      }.not_to change(IssueMergeSubscription, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "does not allow subscriptions for synthetic non-GitHub issues" do
      synthetic_issue = create(
        :issue,
        project: project,
        source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        github_number: 99,
        title: "Code scanning alert",
        github_state: "open"
      )

      expect {
        post project_issue_merge_subscription_path(project, synthetic_issue)
      }.not_to change(IssueMergeSubscription, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You are not authorized to perform this action.")
    end
  end

  describe "GET /projects/new" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get new_project_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the new project form" do
        get new_project_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Add Project")
      end

      it "shows warning when no tokens are available" do
        get new_project_path
        expect(response.body).to include("No GitHub Tokens Available")
      end

      it "shows the form when tokens are available" do
        github_token # create the token
        get new_project_path
        expect(response.body).to include("Repository")
        expect(response.body).to include("Select a token first...")
      end

      it "renders the repository select as disabled initially" do
        github_token # create the token
        get new_project_path
        expect(response.body).to include('name="repository_selection"')
        expect(response.body).to match(/<select\s(?:"[^"]*"|[^">])*\sdisabled[\s>]/m)
      end

      it "does not show revoked tokens in the dropdown" do
        create(:github_token, :revoked, account: account, name: "Revoked Token")
        create(:github_token, account: account, name: "Active Token")
        get new_project_path
        expect(response.body).to include("Active Token")
        expect(response.body).not_to include("Revoked Token")
      end
    end
  end

  describe "POST /projects" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post projects_path, params: { project: { owner: "octocat", repo: "hello-world", github_token_id: 1 } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      let(:valid_params) do
        {
          project: {
            github_token_id: github_token.id,
            owner: "octocat",
            repo: "hello-world",
            name: "My Test Project"
          }
        }
      end

      let(:repo_response) do
        OpenStruct.new(
          id: 123456,
          name: "hello-world",
          default_branch: "main"
        )
      end

      context "with valid parameters" do
        before do
          github_client = instance_double(GithubClient)
          allow(GithubClient).to receive(:new).and_return(github_client)
          allow(github_client).to receive(:repository).with("octocat/hello-world").and_return(repo_response)
          allow(github_client).to receive(:labels).with("octocat/hello-world").and_return([])
          allow(github_client).to receive(:create_label)
        end

        it "creates a new project" do
          expect {
            post projects_path, params: valid_params
          }.to change(Project, :count).by(1)
        end

        it "redirects to the project show page with success message" do
          post projects_path, params: valid_params
          expect(response).to redirect_to(project_path(Project.last))
          expect(flash[:notice]).to include("successfully added")
        end

        it "associates the project with the current account" do
          post projects_path, params: valid_params
          expect(Project.last.account).to eq(account)
        end

        it "associates the project with the current user as creator" do
          post projects_path, params: valid_params
          expect(Project.last.created_by).to eq(user)
        end

        it "fetches GitHub metadata" do
          post projects_path, params: valid_params
          project = Project.last
          expect(project.github_id).to eq(123456)
          expect(project.default_branch).to eq("main")
        end

        it "uses repository name as display name if not provided" do
          post projects_path, params: {
            project: {
              github_token_id: github_token.id,
              owner: "octocat",
              repo: "hello-world"
            }
          }
          expect(Project.last.name).to eq("hello-world")
        end
      end

      context "without a github token selected" do
        it "re-renders the form with errors" do
          github_token # ensure at least one token exists so form renders
          post projects_path, params: {
            project: {
              owner: "octocat",
              repo: "hello-world"
            }
          }
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("must be selected")
        end
      end

      context "when repository is not found" do
        before do
          github_client = instance_double(GithubClient)
          allow(GithubClient).to receive(:new).and_return(github_client)
          allow(github_client).to receive(:repository).and_raise(GithubClient::NotFoundError.new("Not Found"))
        end

        it "re-renders the form with error message" do
          post projects_path, params: valid_params
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("Repository not found")
        end

        it "does not create the project" do
          expect {
            post projects_path, params: valid_params
          }.not_to change(Project, :count)
        end
      end

      context "when GitHub API returns authentication error" do
        before do
          github_client = instance_double(GithubClient)
          allow(GithubClient).to receive(:new).and_return(github_client)
          allow(github_client).to receive(:repository).and_raise(GithubClient::AuthenticationError.new("Bad credentials"))
        end

        it "re-renders the form with error message" do
          post projects_path, params: valid_params
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("authentication failed")
        end
      end

      context "when GitHub API returns rate limit error" do
        before do
          github_client = instance_double(GithubClient)
          allow(GithubClient).to receive(:new).and_return(github_client)
          allow(github_client).to receive(:repository).and_raise(GithubClient::RateLimitError.new(1.hour.from_now))
        end

        it "re-renders the form with rate limit error message" do
          post projects_path, params: valid_params
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("rate limit exceeded")
        end
      end

      context "when using another account's token" do
        before do
          github_client = instance_double(GithubClient)
          allow(GithubClient).to receive(:new).and_return(github_client)
          allow(github_client).to receive(:repository).with("octocat/hello-world").and_return(repo_response)
        end

        it "does not allow creating project with another account's token" do
          other_account = create(:account)
          other_token = create(:github_token, account: other_account)
          github_token # ensure current account has at least one token

          post projects_path, params: {
            project: {
              github_token_id: other_token.id,
              owner: "octocat",
              repo: "hello-world"
            }
          }
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("must belong to the same account")
          expect(GithubClient).not_to have_received(:new)
        end
      end
    end
  end

  describe "GET /projects/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)
        get project_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows the project details" do
        project = create(:project, account: account, github_token: github_token, name: "My Project")
        get project_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("My Project")
      end

      it "shows project statistics" do
        project = create(:project, :with_metrics, account: account, github_token: github_token)
        create_list(:agent_run, 3, project: project, status: "completed")
        get project_path(project)
        expect(response.body).to include("Runs:")
        expect(response.body).to include("Completed:")
        expect(response.body).to include("$15.00")
      end

      it "shows quality summary when quality metrics exist" do
        project = create(:project, account: account, github_token: github_token)
        agent_run = create(:agent_run, project: project, status: "completed")
        create(:quality_metric, agent_run: agent_run, composite_score: 0.85)

        get project_path(project)

        expect(response.body).to include("Average Quality Score")
        expect(response.body).to include("Bundle Analysis")
        expect(response.body).to include("View Dashboard")
      end

      it "does not show quality summary when no quality metrics exist" do
        project = create(:project, account: account, github_token: github_token)

        get project_path(project)

        expect(response.body).not_to include("Average Quality Score")
      end

      it "shows recent agent runs" do
        project = create(:project, account: account, github_token: github_token)
        run = create(:agent_run, project: project, agent_type: "claude_code", status: "completed")
        get project_path(project)
        expect(response.body).to include("Recent Agent Runs")
        expect(response.body).to include(project_agent_run_path(project, run))
      end

      it "shows the provider column for recent agent runs" do
        project = create(:project, account: account, github_token: github_token, created_by: user)
        provider = create(:provider, user: project.effective_owner, provider_key: "codex")
        run = create(:agent_run, project: project, provider: provider, final_provider: provider.routing_key)

        get project_path(project)

        document = Nokogiri::HTML(response.body)
        section = document.at_css(%(div[id="#{ActionView::RecordIdentifier.dom_id(project, :agent_runs)}"]))

        expect(section).to be_present
        expect(section.css("thead th").map { |header| header.text.squish }).to include("Provider")

        row = section.at_css(%(a[href="#{project_agent_run_path(project, run)}"]))&.ancestors("tr")&.first

        expect(row).to be_present
        expect(row.text).to include(provider.display_name)
      end

      it "shows the final provider label for legacy fallback runs in recent agent runs" do
        project = create(:project, account: account, github_token: github_token, created_by: user)
        initial_provider = create(:provider, user: project.effective_owner, provider_key: "codex")
        run = create(:agent_run, project: project, provider: initial_provider, final_provider: "cursor")

        get project_path(project)

        document = Nokogiri::HTML(response.body)
        section = document.at_css(%(div[id="#{ActionView::RecordIdentifier.dom_id(project, :agent_runs)}"]))
        row = section.at_css(%(a[href="#{project_agent_run_path(project, run)}"]))&.ancestors("tr")&.first

        expect(row).to be_present
        expect(row.text).to include(Provider.display_name_for("cursor"))
      end

      it "renders unsupported provider identifiers in recent agent runs without error" do
        project = create(:project, account: account, github_token: github_token, created_by: user)
        run = create(:agent_run, project: project, provider: nil, final_provider: "api", agent_type: "api")

        get project_path(project)

        document = Nokogiri::HTML(response.body)
        section = document.at_css(%(div[id="#{ActionView::RecordIdentifier.dom_id(project, :agent_runs)}"]))
        row = section.at_css(%(a[href="#{project_agent_run_path(project, run)}"]))&.ancestors("tr")&.first

        expect(response).to have_http_status(:ok)
        expect(row).to be_present
        expect(row.text).to include("Api")
      end

      it "links to PR in context column for review goal runs on project page" do
        project = create(:project, account: account, github_token: github_token)
        run = create(:agent_run, :review_goal, :completed, project: project)
        get project_path(project)
        expect(response.body).to include("PR ##{run.source_pull_request_number}")
        expect(response.body).to include("#{project.github_url}/pull/#{run.source_pull_request_number}")
      end

      it "shows review link in actions column when review_url is present on project page" do
        project = create(:project, account: account, github_token: github_token)
        create(:agent_run, :with_review, project: project)
        get project_path(project)
        expect(response.body).to include("Review")
        expect(response.body).to include("https://github.com/example/repo/pull/10#pullrequestreview-123456")
      end

      it "shows PR link in actions column for completed create_pr runs on project page" do
        project = create(:project, account: account, github_token: github_token)
        create(:agent_run, :completed, project: project)
        get project_path(project)
        expect(response.body).to include(">PR</a>")
        expect(response.body).to include("https://github.com/example/repo/pull/1")
      end

      it "shows the stale cleanup button when stale runs exist and the user can update the project" do
        project = create(:project, account: account, github_token: github_token)
        create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)

        get project_path(project)

        expect(response.body).to include("Clean Up Stale Runs")
        expect(response.body).to include(cleanup_stale_runs_project_path(project))
      end

      it "hides the stale cleanup button when no stale runs exist" do
        project = create(:project, account: account, github_token: github_token)
        create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff + 1.minute)

        get project_path(project)

        expect(response.body).not_to include("Clean Up Stale Runs")
      end

      it "shows the stale cleanup button for stale claimed runs" do
        project = create(:project, account: account, github_token: github_token)
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-wf", project: project)
        stale_run.update_column(:updated_at, AgentRun.stale_claimed_cutoff - 1.minute)

        get project_path(project)

        expect(response.body).to include("Clean Up Stale Runs")
      end

      it "hides the stale cleanup button for viewers" do
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account, github_token: github_token)
        create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)

        sign_out user
        sign_in viewer

        get project_path(project)

        expect(response.body).not_to include("Clean Up Stale Runs")
      end

      it "shows the Goal column with the PR Creation label for create_pr runs" do
        project = create(:project, account: account, github_token: github_token)
        agent_run = create(:agent_run, project: project, status: "completed", goal: "create_pr")
        get project_path(project)
        document = Nokogiri::HTML(response.body)
        goal_index = document.css("table thead th").find_index { |header| header.text.squish == "Goal" }
        row = document.at_css(%(tr#agent_run_#{agent_run.id}))

        expect(goal_index).not_to be_nil
        expect(row).to be_present
        expect(row.css("td")[goal_index].text).to include("PR Creation")
      end

      it "shows the Goal column with the Issue Creation label for create_issue runs" do
        project = create(:project, account: account, github_token: github_token)
        agent_run = create(:agent_run, :create_issue_goal, project: project, status: "completed")
        get project_path(project)
        document = Nokogiri::HTML(response.body)
        goal_index = document.css("table thead th").find_index { |header| header.text.squish == "Goal" }
        row = document.at_css(%(tr#agent_run_#{agent_run.id}))

        expect(goal_index).not_to be_nil
        expect(row).to be_present
        expect(row.css("td")[goal_index].text).to include("Issue Creation")
      end

      it "shows issue link when created_issue_url is present" do
        project = create(:project, account: account, github_token: github_token)
        create(:agent_run, :with_created_issue, :completed, project: project)
        get project_path(project)
        expect(response.body).to include("Issue #42")
        expect(response.body).to include("https://github.com/example/repo/issues/42")
      end

      it "shows empty state when no agent runs exist" do
        project = create(:project, account: account, github_token: github_token)
        get project_path(project)
        expect(response.body).to include("No agent runs yet")
      end

      it "links to the GitHub repository" do
        project = create(:project, account: account, github_token: github_token, owner: "octocat", repo: "hello")
        get project_path(project)
        expect(response.body).to include("https://github.com/octocat/hello")
      end

      it "shows Quick Run buttons next to issues" do
        project = create(:project, account: account, github_token: github_token)
        issue = create(:issue, project: project, github_number: 5, title: "Test issue", github_state: "open")
        get project_path(project)
        expect(response.body).to include(quick_create_project_agent_runs_path(project, issue_id: issue.id))
        expect(response.body).to include("Quick Run")
      end

      it "disables Quick Run when the issue has an open paid-generated PR" do
        project = create(:project, account: account, github_token: github_token)
        issue = create(:issue, project: project, github_number: 5, title: "Test issue", github_state: "open")
        pr = create(:issue, :pull_request, project: project, github_number: 77,
          github_state: "open", parent_issue: issue)
        create(:agent_run, :completed, project: project, issue: issue,
          pull_request_number: pr.github_number,
          pull_request_url: "https://github.com/example/repo/pull/#{pr.github_number}")

        get project_path(project)

        expect(response.body).not_to include(quick_create_project_agent_runs_path(project, issue_id: issue.id))
        expect(response.body).to include(%(data-issue-quick-run-disabled="true"))
        expect(response.body).to include("Quick run on PR ##{pr.github_number}")
      end

      it "keeps Quick Run enabled and still shows a PR-link icon when the PR was not paid-generated" do
        project = create(:project, account: account, github_token: github_token, owner: "octocat", repo: "hello")
        issue = create(:issue, project: project, github_number: 5, title: "Test issue", github_state: "open")
        create(:issue, :pull_request, project: project, github_number: 78,
          github_state: "open", parent_issue: issue)

        get project_path(project)

        expect(response.body).to include(quick_create_project_agent_runs_path(project, issue_id: issue.id))
        expect(response.body).to include("https://github.com/octocat/hello/pull/78")
        expect(response.body).to include("PR #78")
      end

      it "re-enables Quick Run after the paid-generated PR is closed" do
        project = create(:project, account: account, github_token: github_token)
        issue = create(:issue, project: project, github_number: 5, title: "Test issue", github_state: "open")
        pr = create(:issue, :pull_request, :closed, project: project, github_number: 77,
          parent_issue: issue)
        create(:agent_run, :completed, project: project, issue: issue,
          pull_request_number: pr.github_number,
          pull_request_url: "https://github.com/example/repo/pull/#{pr.github_number}")

        get project_path(project)

        expect(response.body).to include(quick_create_project_agent_runs_path(project, issue_id: issue.id))
      end

      it "color-codes only priority labels in synced issues" do
        project = create(:project, account: account, github_token: github_token,
          priority_labels: { "P1" => "urgent", "P2" => "high-touch", "P3" => "later" })
        create(:issue, project: project, github_number: 5, title: "Styled labels",
          github_state: "open", labels: [ "urgent", "bug", "later", "P0" ])

        get project_path(project)

        expect(response.body).to match(/<span class="[^"]*bg-red-100 text-red-800[^"]*">urgent<\/span>/)
        expect(response.body).to match(/<span class="[^"]*bg-blue-100 text-blue-800[^"]*">later<\/span>/)
        expect(response.body).to match(/<span class="[^"]*bg-red-700 text-red-50[^"]*">P0<\/span>/)
        expect(response.body).to match(/<span class="[^"]*bg-gray-100 text-gray-600[^"]*">bug<\/span>/)
      end

      it "shows Quick Run buttons next to pull requests" do
        project = create(:project, account: account, github_token: github_token)
        pr = create(:issue, :pull_request, project: project, github_number: 8, title: "Test PR", github_state: "open")
        get project_path(project)
        expect(response.body).to include(quick_create_project_agent_runs_path(project, pull_request_id: pr.id))
        expect(response.body).to include("Quick Run")
      end

      it "shows recently merged PRs with linked closed issues when auto-merge is enabled" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "all")
        issue = create(:issue, project: project, github_number: 21, title: "Fix flaky spec")
        pr = create(:issue, :pull_request, :closed, project: project, parent_issue: issue,
          github_number: 34, title: "Fix flaky spec in CI", pr_review_phase: "merged",
          github_updated_at: Time.utc(2026, 4, 1, 12, 0, 0))

        get project_path(project)

        expect(response.body).to include("Recently Merged PRs")
        expect(response.body).to include(%(id="recent_merge_issue_#{pr.id}"))

        recent_merge_row = response.body.match(/<tr[^>]*id="recent_merge_issue_#{pr.id}"[^>]*>.*?<\/tr>/m)&.[](0)
        expect(recent_merge_row).to be_present, "expected to find a <tr> with id='recent_merge_issue_#{pr.id}'"

        expect(recent_merge_row).to include(">#34<")
        expect(recent_merge_row).to include(">Fix flaky spec in CI<")
        expect(recent_merge_row).to match(/<a [^>]*>#21<\/a>/)
        expect(recent_merge_row).to include(">Fix flaky spec<")
      end

      it "shows the issue from cached closing references when parent_issue is absent" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "all")
        create(:issue, project: project, github_number: 21, title: "Fix flaky spec")
        pr = create(:issue, :pull_request, :closed, project: project,
          github_number: 34, title: "Fix flaky spec in CI", pr_review_phase: "merged",
          body: "Closes #21")

        get project_path(project)

        expect(response.body).to include("Recently Merged PRs")
        expect(response.body).to include(%(id="recent_merge_issue_#{pr.id}"))

        recent_merge_row = response.body.match(/<tr[^>]*id="recent_merge_issue_#{pr.id}"[^>]*>.*?<\/tr>/m)&.[](0)
        expect(recent_merge_row).to be_present, "expected to find a <tr> with id='recent_merge_issue_#{pr.id}'"

        expect(recent_merge_row).to include(">#34<")
        expect(recent_merge_row).to include(">Fix flaky spec in CI<")
        expect(recent_merge_row).to match(/<a [^>]*>#21<\/a>/)
        expect(recent_merge_row).to include(">Fix flaky spec<")
      end

      it "shows the empty recent merged PR state when auto-merge is enabled but nothing has merged" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "all")

        get project_path(project)

        expect(response.body).to include("Recently Merged PRs")
        expect(response.body).to include("No recently merged PRs")
      end

      it "hides the recent merged PR section when auto-merge is disabled" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "off")
        issue = create(:issue, project: project, github_number: 21, title: "Fix flaky spec")
        create(:issue, :pull_request, :closed, project: project, parent_issue: issue,
          github_number: 34, title: "Fix flaky spec in CI", pr_review_phase: "merged")

        get project_path(project)

        expect(response.body).not_to include("Recently Merged PRs")
      end

      it "shows pause button for PRs with automation label" do
        project = create(:project, account: account, github_token: github_token)
        pr = create(:issue, :pull_request, project: project, github_number: 10, title: "Automated PR",
          github_state: "open", labels: [ project.automation_label_name ])
        get project_path(project)
        expect(response.body).to include(
          toggle_auto_continue_pause_project_agent_runs_path(project, pull_request_id: pr.id)
        )
        expect(response.body).to include("Pause auto-continue")
      end

      it "hides pause button for PRs without automation label" do
        project = create(:project, account: account, github_token: github_token)
        pr = create(:issue, :pull_request, project: project, github_number: 11, title: "Release PR",
          github_state: "open", labels: [ "release" ])
        get project_path(project)
        expect(response.body).not_to include(
          toggle_auto_continue_pause_project_agent_runs_path(project, pull_request_id: pr.id)
        )
        expect(response.body).not_to include("Pause auto-continue")
      end

      it "shows Paused badge for paused PRs with automation label" do
        project = create(:project, account: account, github_token: github_token)
        create(:issue, :pull_request, project: project, github_number: 12, title: "Automated PR",
          github_state: "open", labels: [ project.automation_label_name ], auto_continue_paused: true)
        get project_path(project)
        expect(response.body).to include("bg-yellow-100")
        expect(response.body).to include(">Paused</span>")
      end

      it "surfaces paused PR runs with an inline resume action" do
        project = create(:project, account: account, github_token: github_token)
        pr = create(:issue, :pull_request, project: project, github_number: 12, title: "Automated PR",
          github_state: "open", labels: [ project.automation_label_name ])
        run = create(:agent_run, :paused, project: project, issue: pr,
          source_pull_request_number: pr.github_number, goal: "create_pr",
          guardrail_violation_type: "time_limit",
          guardrail_context: { "details" => "Execution time limit of 3600s exceeded" })

        get project_path(project)

        expect(response.body).to include("Paused Work")
        expect(response.body).to include("Paused by time limit")
        expect(response.body).to include("Execution time limit of 3600s exceeded")
        expect(response.body).to include(resume_project_agent_run_path(project, run))
        expect(response.body).to include("Resume Run")
      end

      it "does not show a redundant generic paused badge when a paused PR run is present" do
        project = create(:project, account: account, github_token: github_token)
        pr = create(:issue, :pull_request, project: project, github_number: 14, title: "Guardrail-paused PR",
          github_state: "open", labels: [ project.automation_label_name ], auto_continue_paused: true)
        create(:agent_run, :paused, project: project, issue: pr,
          source_pull_request_number: pr.github_number, goal: "create_pr",
          guardrail_violation_type: "time_limit",
          guardrail_context: { "details" => "Execution time limit of 3600s exceeded" })

        get project_path(project)

        pr_row = Nokogiri::HTML(response.body).at_css(%(li[id="#{ActionView::RecordIdentifier.dom_id(pr)}"]))

        expect(pr_row).to be_present
        expect(pr_row.text).to include("Paused by time limit")
        expect(pr_row.text).not_to include("PausedPaused")
      end

      it "surfaces paused issue runs with an inline resume action" do
        project = create(:project, account: account, github_token: github_token)
        issue = create(:issue, project: project, github_number: 25, title: "Fix sync bug")
        run = create(:agent_run, :paused, project: project, issue: issue,
          goal: "create_pr", guardrail_violation_type: "time_limit",
          guardrail_context: { "details" => "Execution time limit of 3600s exceeded" })

        get project_path(project)

        expect(response.body).to include("Paused by time limit")
        expect(response.body).to include(resume_project_agent_run_path(project, run))
        expect(response.body).to include("Resume Run")
      end

      it "hides Paused badge for paused PRs without automation label" do
        project = create(:project, account: account, github_token: github_token)
        create(:issue, :pull_request, project: project, github_number: 13, title: "Release PR",
          github_state: "open", labels: [ "release" ], auto_continue_paused: true)
        get project_path(project)
        expect(response.body).not_to include(">Paused</span>")
      end

      it "shows automation settings with their current state" do
        project = create(:project, account: account, github_token: github_token,
          auto_add_labels_enabled: true, automation_on_label_enabled: false,
          auto_pick_enabled: true, auto_merge_mode: "off", auto_fix_merge_conflicts: true,
          auto_scan_security: true)
        get project_path(project)
        expect(response.body).to include("Configuration")
        # Ensure the old separate "Automation" section header is gone (the word still appears in setting labels)
        expect(response.body).not_to match(%r{<summary[^>]*>\s*Automation\s*</summary>}m)
        # Ensure the Configuration details element is collapsed by default (no `open` attribute)
        expect(response.body).to match(
          %r{<details[^>]*>\s*<summary[^>]*>\s*Configuration\s*</summary>}m
        )
        expect(response.body).not_to match(%r{<details[^>]*\bopen\b}m)

        {
          "Auto-Add Labels" => "Enabled", "Automation on Label" => "Disabled",
          "Auto-Pick Issues" => "Enabled", "Auto-Merge" => "Off",
          "Auto-Fix Merge Conflicts" => "Enabled"
        }.each do |label, state|
          expect(response.body).to match(
            %r{<dt[^>]*>\s*#{Regexp.escape(label)}\s*</dt>\s*<dd[^>]*>.*?\b#{state}\b.*?</dd>}m
          )
        end
      end

      it "shows security scanning as enabled without a severity threshold" do
        project = create(:project, account: account, github_token: github_token,
          auto_scan_security: true)
        get project_path(project)

        expect(response.body).to match(
          %r{<dt[^>]*>\s*Auto-Scan Security Alerts\s*</dt>\s*<dd[^>]*>.*?\bEnabled\b.*?</dd>}m
        )
        expect(response.body).not_to include("Severity Threshold")
      end

      it "shows security scanning as disabled when off" do
        project = create(:project, account: account, github_token: github_token,
          auto_scan_security: false)

        get project_path(project)

        expect(response.body).to match(
          %r{<dt[^>]*>\s*Auto-Scan Security Alerts\s*</dt>\s*<dd[^>]*>.*?\bDisabled\b.*?</dd>}m
        )
      end

      it "shows edit automation link for users with update permission" do
        owner = create(:user, :owner, account: account)
        sign_in owner
        project = create(:project, account: account, github_token: github_token)
        get project_path(project)
        expect(response.body).to include("Edit automation settings")
      end

      it "hides edit automation link for users without update permission" do
        viewer = create(:user, :viewer, account: account)
        sign_in viewer
        project = create(:project, account: account, github_token: github_token)
        get project_path(project)
        expect(response.body).not_to include("Edit automation settings")
      end

      context "when knowledge collection has failed" do
        it "shows failure banner with failed collector names and error messages" do
          project = create(:project, account: account, github_token: github_token, knowledge_status: "failed")
          version = create(:project_version, project: project)
          create(:collector_run, :failed, project_version: version, collector_type: "code_structure",
            error_message: "Repository clone failed")
          create(:collector_run, :failed, project_version: version, collector_type: "dependency_graph",
            error_message: "Timeout parsing lockfile")

          get project_path(project)

          expect(response.body).to include("Knowledge collection failed")
          expect(response.body).to include("code_structure")
          expect(response.body).to include("Repository clone failed")
          expect(response.body).to include("dependency_graph")
          expect(response.body).to include("Timeout parsing lockfile")
        end

        it "shows fallback message when no collector-level errors exist" do
          project = create(:project, account: account, github_token: github_token, knowledge_status: "failed")
          create(:project_version, project: project)

          get project_path(project)

          expect(response.body).to include("Knowledge collection failed")
          expect(response.body).to include("no collector-level error details are available")
        end

        it "shows inline error rows for failed collector runs in the table" do
          project = create(:project, account: account, github_token: github_token, knowledge_status: "failed")
          version = create(:project_version, project: project)
          create(:collector_run, :failed, project_version: version, collector_type: "code_structure",
            error_message: "Clone failed")

          get project_path(project)

          expect(response.body).to include("bg-red-50")
          expect(response.body).to include("Error:")
          expect(response.body).to include("Clone failed")
        end

        it "redacts secrets from error messages in the banner and inline rows" do
          project = create(:project, account: account, github_token: github_token, knowledge_status: "failed")
          version = create(:project_version, project: project)
          create(:collector_run, :failed, project_version: version, collector_type: "code_structure",
            error_message: "Clone failed: https://ghp_abc123def456ghi789jkl012mno345pqr678@github.com/org/repo.git")

          get project_path(project)

          expect(response.body).to include("code_structure")
          expect(response.body).not_to include("ghp_abc123def456ghi789jkl012mno345pqr678")
        end

        it "does not show stale errors from previous versions in the banner" do
          project = create(:project, account: account, github_token: github_token, knowledge_status: "failed")
          old_version = create(:project_version, project: project, created_at: 1.day.ago)
          create(:collector_run, :failed, project_version: old_version, collector_type: "old_collector",
            error_message: "Old error from previous version")
          new_version = create(:project_version, project: project, created_at: Time.current)
          create(:collector_run, :completed, project_version: new_version, collector_type: "new_collector")

          get project_path(project)

          doc = Nokogiri::HTML(response.body)
          banner = doc.at_css("[role='alert']")
          expect(banner).to be_present
          expect(banner.text).not_to include("old_collector")
          expect(banner.text).to include("no collector-level error details are available")
        end
      end

      it "does not allow viewing projects from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)
        get project_path(other_project)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /projects/:id/edit" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)
        get edit_project_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before do
        sign_in user
        allow(Projects::Screenshots::RepoConfig).to receive(:call).and_return(empty_screenshot_repo_config_result)
      end

      it "shows the edit form" do
        project = create(:project, account: account, github_token: github_token, name: "My Project")
        get edit_project_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Edit Project")
        expect(response.body).to include("My Project")
      end

      it "shows security automation controls in the automation section" do
        project = create(:project, account: account, github_token: github_token,
          auto_scan_security: true)

        get edit_project_path(project)

        expect(response.body).to include("Auto-Scan Security Alerts")
        expect(response.body).to include('name="project[auto_scan_security]"')
      end

      it "shows security scanning controls when auto_scan_security is disabled" do
        project = create(:project, account: account, github_token: github_token,
          auto_scan_security: false)

        get edit_project_path(project)

        expect(response.body).to include("Auto-Scan Security Alerts")
        expect(response.body).to include('name="project[auto_scan_security]"')
      end

      it "shows the repository name (not editable)" do
        project = create(:project, account: account, github_token: github_token, owner: "octocat", repo: "hello")
        get edit_project_path(project)
        expect(response.body).to include("octocat/hello")
        expect(response.body).to include("cannot be changed")
      end

      it "shows quality pause details and resume action when paused" do
        project = create(:project, account: account, github_token: github_token,
          quality_paused_at: 1.hour.ago,
          quality_pause_metadata: {
            "composite_score" => 0.32,
            "threshold" => 0.5,
            "metric_type" => "composite_score",
            "goal_type" => "create_pr",
            "sample_size" => 3,
            "recent_scores" => [ 0.2, 0.3, 0.46 ]
          })

        get edit_project_path(project)

        expect(response.body).to include("Quality Pause")
        expect(response.body).to include("Paused")
        expect(response.body).to include("32.0%")
        expect(response.body).to include("50.0%")
        expect(response.body).to include("20.0%")
        expect(response.body).to include(quality_resume_project_path(project))
      end

      it "shows running quality pause status when not paused" do
        project = create(:project, account: account, github_token: github_token)

        get edit_project_path(project)

        expect(response.body).to include("Quality Pause")
        expect(response.body).to include("Automatic work is not paused by quality gates.")
        expect(response.body).not_to include(quality_resume_project_path(project))
      end

      it "hides review method settings for disabled review types" do
        project = create(:project, account: account, github_token: github_token, review_settings: {
          "enabled" => false,
          "methods" => {
            "copilot" => { "enabled" => false, "termination" => { "max_review_rounds" => 3 } }
          }
        })

        get edit_project_path(project)

        doc = Nokogiri::HTML(response.body)
        panel = doc.at_css("#review_copilot_settings")
        checkbox = doc.at_css("#review_copilot_enabled")

        expect(panel).to be_present
        expect(panel.has_attribute?("inert")).to be true
        expect(panel["data-collapsible-panel-target"]).to eq("panel")
        expect(checkbox["data-action"]).to eq("change->collapsible-panel#toggle")
      end

      it "shows review method settings for enabled review types" do
        project = create(:project, account: account, github_token: github_token, review_settings: {
          "enabled" => true,
          "methods" => {
            "manual" => {
              "enabled" => true,
              "reviewer_login" => "octocat",
              "termination" => { "max_review_rounds" => 2 }
            }
          }
        })

        get edit_project_path(project)

        doc = Nokogiri::HTML(response.body)
        panel = doc.at_css("#review_manual_settings")

        expect(panel).to be_present
        expect(panel.has_attribute?("inert")).to be false
        expect(panel["class"]).to include("max-h-[2000px]")
      end

      it "shows screenshot settings preview and repo conflicts" do
        project = create(:project, account: account, github_token: github_token, screenshot_settings: {
          "enabled" => true,
          "driver" => "cuprite",
          "service_dependencies" => [ "postgres" ],
          "setup_commands" => [ "bin/setup --skip-server" ],
          "config_path" => ".paid/screenshots.yml"
        })

        allow(Projects::Screenshots::RepoConfig).to receive(:call).and_return(screenshot_repo_config_result(
          config: { "driver" => "playwright", "services" => [ "redis" ] },
          content: <<~YAML
            driver: playwright
            services:
              - redis
          YAML
        ))

        get edit_project_path(project)

        expect(response.body).to include("Screenshots")
        expect(response.body).to include("Merged Config Preview")
        expect(response.body).to include("Config Conflicts")
        expect(response.body).to include("driver: cuprite")
      end
    end
  end

  describe "PATCH /projects/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)
        patch project_path(project), params: { project: { name: "Updated Name" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before do
        sign_in user
        allow(Projects::Screenshots::RepoConfig).to receive(:call).and_return(empty_screenshot_repo_config_result)
      end

      let(:screenshot_update_params) do
        {
          project: {
            screenshot_settings: {
              enabled: "1",
              driver: "cuprite",
              config_path: ".paid/screenshots.yml",
              auto_capture: "1",
              service_dependencies: [ "postgres", "redis" ],
              setup_commands_text: "bin/setup --skip-server\nbin/rails db:prepare\n"
            }
          }
        }
      end

      it "updates the project" do
        project = create(:project, account: account, github_token: github_token, name: "Old Name")
        patch project_path(project), params: { project: { name: "New Name" } }
        expect(project.reload.name).to eq("New Name")
      end

      it "redirects to the project with success message" do
        project = create(:project, account: account, github_token: github_token)
        patch project_path(project), params: { project: { name: "Updated Name" } }
        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to include("successfully updated")
      end

      it "allows updating poll interval" do
        project = create(:project, account: account, github_token: github_token, poll_interval_seconds: 60)
        patch project_path(project), params: { project: { poll_interval_seconds: 120 } }
        expect(project.reload.poll_interval_seconds).to eq(120)
      end

      it "allows toggling active status" do
        project = create(:project, account: account, github_token: github_token, active: true)
        patch project_path(project), params: { project: { active: false } }
        expect(project.reload.active).to be false
      end

      it "allows updating auto_fix_merge_conflicts" do
        project = create(:project, account: account, github_token: github_token, auto_fix_merge_conflicts: false)
        patch project_path(project), params: { project: { auto_fix_merge_conflicts: true } }
        expect(project.reload.auto_fix_merge_conflicts).to be true
      end

      it "persists max draft review rounds" do
        project = create(:project, account: account, github_token: github_token, max_draft_review_rounds: 10)

        patch project_path(project), params: { project: { max_draft_review_rounds: 4 } }

        expect(response).to redirect_to(project_path(project))
        expect(project.reload.max_draft_review_rounds).to eq(4)
      end

      it "persists screenshot settings" do
        project = create(:project, account: account, github_token: github_token)
        patch project_path(project), params: screenshot_update_params

        expect(response).to redirect_to(project_path(project))
        expect(project.reload.screenshot_settings).to include(
          "enabled" => true,
          "driver" => "cuprite",
          "config_path" => ".paid/screenshots.yml",
          "auto_capture" => true,
          "service_dependencies" => %w[postgres redis],
          "setup_commands" => [ "bin/setup --skip-server", "bin/rails db:prepare" ]
        )
      end

      it "re-renders validation errors when screenshot repo config loading fails" do
        project = create(:project, account: account, github_token: github_token)
        allow(Projects::Screenshots::RepoConfig).to receive(:call).and_raise(StandardError, "GitHub is down")

        patch project_path(project), params: { project: { name: "" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Could not load repository screenshot config: GitHub is down")
      end

      it "allows updating priority label names" do
        project = create(:project, account: account, github_token: github_token)
        patch project_path(project), params: {
          project: { priority_labels: { "P1" => "urgent", "P2" => "normal", "P3" => "low" } }
        }
        expect(response).to redirect_to(project)
        expect(project.reload.priority_labels).to eq("P1" => "urgent", "P2" => "normal", "P3" => "low")
      end

      it "rejects blank priority label values" do
        project = create(:project, account: account, github_token: github_token,
          priority_labels: { "P1" => "P1", "P2" => "P2", "P3" => "P3" })
        patch project_path(project), params: {
          project: { priority_labels: { "P1" => "", "P2" => "normal", "P3" => "low" } }
        }
        expect(response).to have_http_status(:unprocessable_content)
        expect(project.reload.priority_labels).to eq("P1" => "P1", "P2" => "P2", "P3" => "P3")
      end

      it "preserves priority labels when param is omitted" do
        project = create(:project, account: account, github_token: github_token,
          priority_labels: { "P1" => "urgent", "P2" => "normal", "P3" => "low" })
        patch project_path(project), params: { project: { generated_label_name: "ai-gen" } }
        expect(response).to redirect_to(project)
        expect(project.reload.priority_labels).to eq("P1" => "urgent", "P2" => "normal", "P3" => "low")
      end

      it "allows updating security scanning settings" do
        project = create(:project, account: account, github_token: github_token,
          auto_scan_security: false)

        patch project_path(project), params: { project: { auto_scan_security: true } }

        expect(project.reload.auto_scan_security).to be true
      end

      it "allows updating github_token to another valid token" do
        project = create(:project, account: account, github_token: github_token)
        new_token = create(:github_token, account: account, name: "New Token")
        patch project_path(project), params: { project: { github_token_id: new_token.id } }
        expect(project.reload.github_token).to eq(new_token)
      end

      it "does not allow updating to a revoked token" do
        project = create(:project, account: account, github_token: github_token)
        revoked_token = create(:github_token, :revoked, account: account, name: "Revoked Token")
        patch project_path(project), params: { project: { github_token_id: revoked_token.id } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(project.reload.github_token).to eq(github_token)
      end

      context "with invalid parameters" do
        it "re-renders the form with errors" do
          project = create(:project, account: account, github_token: github_token)
          patch project_path(project), params: { project: { poll_interval_seconds: 30 } }
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("greater than or equal to 60")
        end
      end

      context "with review_settings params" do
        let(:project) { create(:project, account: account, github_token: github_token) }

        let(:valid_review_params) do
          { enabled: "1", wait_for_reviews: "1",
            methods: { copilot: { enabled: "1",
                                  termination: { max_review_rounds: "2", stop_when_no_comments: "1",
                                                 quality_threshold: "", timeout_minutes: "" } } } }
        end

        it "persists review_settings with correct JSON types" do
          patch project_path(project), params: { project: { review_settings: valid_review_params } }

          expect(response).to redirect_to(project_path(project))
          rs = project.reload.review_settings
          expect(rs).to include("enabled" => true, "wait_for_reviews" => true)
          term = rs.dig("methods", "copilot", "termination")
          expect(term).to include("max_review_rounds" => 2, "stop_when_no_comments" => true)
          expect(term.values_at("quality_threshold", "timeout_minutes")).to eq([ nil, nil ])
        end

        it "re-renders form when enabled method has invalid max_review_rounds" do
          invalid_params = { enabled: "0",
                             methods: { copilot: { enabled: "1",
                                                   termination: { max_review_rounds: "0", stop_when_no_comments: "0",
                                                                  quality_threshold: "", timeout_minutes: "" } } } }
          patch project_path(project), params: { project: { review_settings: invalid_params } }

          expect(response).to have_http_status(:unprocessable_content)
          expect(project.reload.review_settings).to eq({})
        end

        it "persists max_review_goal_retries for paid_agent and casts correctly" do
          allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
          params_with_retries = { enabled: "1", wait_for_reviews: "0",
                                  methods: { paid_agent: { enabled: "1",
                                                           termination: { max_review_rounds: "5", max_review_goal_retries: "3",
                                                                          stop_when_no_comments: "1",
                                                                          quality_threshold: "", timeout_minutes: "" } } } }
          patch project_path(project), params: { project: { review_settings: params_with_retries } }

          expect(response).to redirect_to(project_path(project))
          term = project.reload.review_settings.dig("methods", "paid_agent", "termination")
          expect(term).to include("max_review_goal_retries" => 3, "max_review_rounds" => 5)
        end

        it "rejects max_review_goal_retries exceeding max_review_rounds" do
          allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
          params_with_retries = { enabled: "1", wait_for_reviews: "0",
                                  methods: { paid_agent: { enabled: "1",
                                                           termination: { max_review_rounds: "3", max_review_goal_retries: "5",
                                                                          stop_when_no_comments: "1",
                                                                          quality_threshold: "", timeout_minutes: "" } } } }
          patch project_path(project), params: { project: { review_settings: params_with_retries } }

          expect(response).to have_http_status(:unprocessable_entity)
          expect(project.reload.review_settings.dig("methods", "paid_agent", "termination", "max_review_goal_retries")).to be_nil
        end

        it "persists manual reviewer_login and casts blank to nil" do
          params_with_reviewer = { enabled: "1", wait_for_reviews: "0",
                                   methods: { manual: { enabled: "1", reviewer_login: "alice",
                                                        termination: { max_review_rounds: "3", stop_when_no_comments: "1",
                                                                       quality_threshold: "", timeout_minutes: "" } } } }
          patch project_path(project), params: { project: { review_settings: params_with_reviewer } }

          expect(response).to redirect_to(project_path(project))
          manual = project.reload.review_settings.dig("methods", "manual")
          expect(manual).to include("enabled" => true, "reviewer_login" => "alice")

          params_blank_reviewer = { enabled: "0", wait_for_reviews: "0",
                                    methods: { manual: { enabled: "0", reviewer_login: "" } } }
          patch project_path(project), params: { project: { review_settings: params_blank_reviewer } }

          expect(response).to redirect_to(project_path(project))
          manual = project.reload.review_settings.dig("methods", "manual")
          expect(manual["reviewer_login"]).to be_nil
        end

        it "persists address_all_bot_reviews as a boolean" do
          params = { enabled: "1", wait_for_reviews: "1", address_all_bot_reviews: "1",
                     methods: { copilot: { enabled: "1",
                                           termination: { max_review_rounds: "2", stop_when_no_comments: "1",
                                                          quality_threshold: "", timeout_minutes: "" } } } }
          patch project_path(project), params: { project: { review_settings: params } }

          expect(response).to redirect_to(project_path(project))
          expect(project.reload.review_settings).to include("address_all_bot_reviews" => true)
        end
      end
    end
  end

  describe "POST /projects/:id/toggle_auto_pick" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)
        post toggle_auto_pick_project_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as owner" do
      before { sign_in user }

      it "enables auto_pick when currently disabled" do
        project = create(:project, account: account, github_token: github_token, auto_pick_enabled: false)
        post toggle_auto_pick_project_path(project)
        expect(project.reload.auto_pick_enabled).to be true
      end

      it "disables auto_pick when currently enabled" do
        project = create(:project, account: account, github_token: github_token, auto_pick_enabled: true)
        post toggle_auto_pick_project_path(project)
        expect(project.reload.auto_pick_enabled).to be false
      end

      it "redirects to the project for HTML requests" do
        project = create(:project, account: account, github_token: github_token)
        post toggle_auto_pick_project_path(project)
        expect(response).to redirect_to(project_path(project))
      end

      it "responds with turbo_stream when requested" do
        project = create(:project, account: account, github_token: github_token, auto_pick_enabled: false)
        post toggle_auto_pick_project_path(project), headers: { "Accept" => "text/vnd.turbo-stream.html" }
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include("turbo-stream")
        expect(response.body).to include("auto_pick_toggle_project_#{project.id}")
      end

      it "responds with index partial for turbo_stream index context" do
        project = create(:project, account: account, github_token: github_token, auto_pick_enabled: false)

        post toggle_auto_pick_project_path(project),
          params: { context: "index" },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include("auto_pick_toggle_project_#{project.id}")
        expect(response.body).to include("Auto-Pick")
        expect(response.body).not_to include("Auto-Pick Issues")
      end

      it "enqueues ProcessRunQueueJob when enabling auto_pick" do
        project = create(:project, account: account, github_token: github_token, auto_pick_enabled: false)
        expect {
          post toggle_auto_pick_project_path(project)
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "does not enqueue ProcessRunQueueJob when disabling auto_pick" do
        project = create(:project, account: account, github_token: github_token, auto_pick_enabled: true)
        expect {
          post toggle_auto_pick_project_path(project)
        }.not_to have_enqueued_job(ProcessRunQueueJob)
      end
    end

    context "when authenticated as viewer" do
      let(:viewer_user) { create(:user, :viewer, account: account) }

      before { sign_in viewer_user }

      it "redirects with authorization error" do
        project = create(:project, account: account, github_token: github_token)
        post toggle_auto_pick_project_path(project)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /projects/:id/quality_resume" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token, quality_paused_at: Time.current)

        post quality_resume_project_path(project)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as owner" do
      before { sign_in user }

      it "resumes a quality-paused project and records an audit event" do
        project = create(:project, account: account, github_token: github_token,
          quality_paused_at: 1.hour.ago,
          quality_pause_metadata: { "threshold" => 0.5 })

        post quality_resume_project_path(project)

        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to eq("Quality pause was resumed.")
        expect(project.reload.quality_paused?).to be false

        event = project.quality_pause_events.resumes.last
        expect(event.metadata).to include(
          "resumed_by_user_id" => user.id,
          "resumed_by_user_email" => user.email
        )
      end

      it "returns resume state as JSON" do
        project = create(:project, account: account, github_token: github_token, quality_paused_at: Time.current)

        post quality_resume_project_path(project, format: :json)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("resumed" => true, "quality_paused" => false)
      end

      it "does not create an audit event when the project is not paused" do
        project = create(:project, account: account, github_token: github_token)

        expect {
          post quality_resume_project_path(project)
        }.not_to change(QualityPauseEvent, :count)

        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to eq("Project is not quality-paused.")
      end

      it "does not resume projects from other accounts" do
        other_account = create(:account)
        other_project = create(:project, account: other_account, quality_paused_at: Time.current)

        expect {
          post quality_resume_project_path(other_project)
        }.not_to change(QualityPauseEvent, :count)

        expect(response).to have_http_status(:not_found)
        expect(other_project.reload.quality_paused?).to be true
      end
    end

    context "when authenticated as viewer" do
      let(:viewer_user) { create(:user, :viewer, account: account) }

      before { sign_in viewer_user }

      it "redirects with authorization error" do
        project = create(:project, account: account, github_token: github_token, quality_paused_at: Time.current)

        post quality_resume_project_path(project)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
        expect(project.reload.quality_paused?).to be true
      end
    end
  end

  describe "POST /projects/:id/toggle_auto_merge" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)
        post toggle_auto_merge_project_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as owner" do
      before { sign_in user }

      it "cycles to dependabot_only when currently off" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "off")
        post toggle_auto_merge_project_path(project)
        expect(project.reload.auto_merge_mode).to eq("dependabot_only")
      end

      it "cycles to all when currently dependabot_only" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "dependabot_only")
        post toggle_auto_merge_project_path(project)
        expect(project.reload.auto_merge_mode).to eq("all")
      end

      it "cycles to off when currently all" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "all")
        post toggle_auto_merge_project_path(project)
        expect(project.reload.auto_merge_mode).to eq("off")
      end

      it "redirects to the project for HTML requests" do
        project = create(:project, account: account, github_token: github_token)
        post toggle_auto_merge_project_path(project)
        expect(response).to redirect_to(project_path(project))
      end

      it "responds with turbo_stream when requested" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "off")
        post toggle_auto_merge_project_path(project), headers: { "Accept" => "text/vnd.turbo-stream.html" }
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include("turbo-stream")
        expect(response.body).to include("auto_merge_toggle_project_#{project.id}")
      end

      it "responds with index partial for turbo_stream index context" do
        project = create(:project, account: account, github_token: github_token, auto_merge_mode: "off")

        post toggle_auto_merge_project_path(project),
          params: { context: "index" },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include("auto_merge_toggle_project_#{project.id}")
        expect(response.body).to include("Auto-Merge")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer_user) { create(:user, :viewer, account: account) }

      before { sign_in viewer_user }

      it "redirects with authorization error" do
        project = create(:project, account: account, github_token: github_token)
        post toggle_auto_merge_project_path(project)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /projects/:id/cleanup_stale_runs" do
    context "when authenticated" do
      before { sign_in user }

      it "cleans up stale running runs and redirects back to the project" do
        project = create(:project, account: account, github_token: github_token)
        stale_run = create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)

        post cleanup_stale_runs_project_path(project)

        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to eq("Cleaned up 1 stale agent run(s).")
        expect(stale_run.reload.status).to eq("timeout")
      end

      it "unclaims stale claimed runs" do
        project = create(:project, account: account, github_token: github_token)
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-wf", project: project)
        stale_run.update_column(:updated_at, AgentRun.stale_claimed_cutoff - 1.minute)

        handle = instance_double(Temporalio::Client::WorkflowHandle)
        temporal_client = instance_double(Temporalio::Client)
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)
        allow(temporal_client).to receive(:workflow_handle).with("test-wf").and_return(handle)
        allow(handle).to receive(:cancel)

        post cleanup_stale_runs_project_path(project)

        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to eq("Cleaned up 1 stale agent run(s).")
        expect(stale_run.reload.temporal_workflow_id).to be_nil
        expect(stale_run.stale_requeue_count).to eq(1)
      end

      it "shows a no-op notice when no stale runs need cleanup" do
        project = create(:project, account: account, github_token: github_token)

        post cleanup_stale_runs_project_path(project)

        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to eq("No stale agent runs needed cleanup.")
      end

      it "forbids viewers" do
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account, github_token: github_token)

        sign_out user
        sign_in viewer

        post cleanup_stale_runs_project_path(project)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("You are not authorized to perform this action.")
      end
    end
  end

  describe "POST /projects/:id/detect_services" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)
        post detect_services_project_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as owner" do
      let(:project) { create(:project, account: account, github_token: github_token) }
      let(:detect_result) do
        Projects::DetectServices::Result.new(detected: [], matched: [], unmatched: [])
      end

      before do
        sign_in user
        allow(Projects::DetectServices).to receive(:call).and_return(detect_result)
      end

      it "redirects to the edit page" do
        post detect_services_project_path(project)
        expect(response).to redirect_to(edit_project_path(project))
      end

      it "shows a notice when no services are detected" do
        post detect_services_project_path(project)
        expect(flash[:notice]).to include("No service dependencies detected")
      end

      context "when services are detected and matched" do
        let(:postgres_container) do
          ServiceContainer.find_by(name: "postgres", account: account) ||
            create(:service_container, account: account, name: "postgres")
        end
        let(:detect_result) do
          Projects::DetectServices::Result.new(
            detected: [ { service: "postgres", source: "Gemfile", dependency: "pg" } ],
            matched: [ postgres_container ],
            unmatched: []
          )
        end

        it "creates project service container associations" do
          expect {
            post detect_services_project_path(project)
          }.to change(ProjectServiceContainer, :count).by(1)
        end

        it "shows a notice with added services" do
          post detect_services_project_path(project)
          expect(flash[:notice]).to include("postgres")
        end

        it "does not duplicate existing associations" do
          create(:project_service_container, project: project, service_container: postgres_container)
          expect {
            post detect_services_project_path(project)
          }.not_to change(ProjectServiceContainer, :count)
        end
      end

      context "when services are detected but unmatched" do
        let(:detect_result) do
          Projects::DetectServices::Result.new(
            detected: [ { service: "elasticsearch", source: "Gemfile", dependency: "searchkick" } ],
            matched: [],
            unmatched: [ { service: "elasticsearch", source: "Gemfile", dependency: "searchkick" } ]
          )
        end

        it "shows a notice about unmatched services" do
          post detect_services_project_path(project)
          expect(flash[:notice]).to include("elasticsearch")
          expect(flash[:notice]).to include("no matching service container")
        end
      end

      context "when GitHub API returns an error" do
        before do
          allow(Projects::DetectServices).to receive(:call)
            .and_raise(GithubClient::ApiError.new("API rate limit exceeded"))
        end

        it "redirects with an alert" do
          post detect_services_project_path(project)
          expect(response).to redirect_to(edit_project_path(project))
          expect(flash[:alert]).to include("Could not detect services")
        end
      end
    end

    context "when authenticated as viewer" do
      let(:viewer_user) { create(:user, :viewer, account: account) }

      before { sign_in viewer_user }

      it "redirects with authorization error" do
        project = create(:project, account: account, github_token: github_token)
        post detect_services_project_path(project)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /projects/:id/detect_screenshot_settings" do
    let(:project) { create(:project, account: account, github_token: github_token) }

    before { sign_in user }

    it "stores detected screenshot suggestions and redirects to the screenshots section" do
      result = Projects::Screenshots::DetectFramework::Result.new(
        framework: "Rails",
        confidence: "high",
        driver: "cuprite",
        service_dependencies: [ "postgres" ],
        setup_commands: [ "bin/setup --skip-server" ],
        suggested_config: { "driver" => "cuprite" },
        suggested_yaml: "driver: cuprite\n",
        detected_at: Time.current.iso8601
      )
      allow(Projects::Screenshots::DetectFramework).to receive(:call).and_return(result)

      post detect_screenshot_settings_project_path(project)

      expect(response).to redirect_to(edit_project_path(project, anchor: "screenshots"))
      expect(project.reload.screenshot_settings).to include(
        "driver" => "cuprite",
        "service_dependencies" => [ "postgres" ],
        "setup_commands" => [ "bin/setup --skip-server" ]
      )
      expect(project.reload.screenshot_settings.dig("detection", "framework")).to eq("Rails")
    end
  end

  describe "POST /projects/:id/commit_screenshot_config" do
    let(:pull_request_url) { "https://github.com/acme/widgets/pull/42" }
    let(:submitted_screenshot_settings) do
      {
        enabled: "1",
        driver: "cuprite",
        config_path: ".paid/custom-screenshots.yml",
        auto_capture: "0",
        service_dependencies: [ "postgres", "redis" ],
        setup_commands_text: "bin/setup --skip-server\nbin/rails db:prepare\n"
      }
    end
    let(:generated_yaml) do
      <<~YAML
        ---
        driver: cuprite
        auto_capture: false
        services:
        - postgres
        - redis
        setup:
        - bin/setup --skip-server
        - bin/rails db:prepare
      YAML
    end
    let(:project) do
      create(:project, account: account, github_token: github_token, screenshot_settings: {
        "config_path" => ".paid/screenshots.yml",
        "auto_capture" => true,
        "detection" => { "suggested_yaml" => "driver: playwright\n" }
      })
    end
    let(:repo_config_result) do
      Projects::Screenshots::RepoConfig::Result.new(config: {}, content: nil, error: nil)
    end
    let(:commit_result) do
      Projects::Screenshots::CommitConfig::Result.new(pull_request_url: pull_request_url)
    end

    before { sign_in user }

    def stub_commit_config(commit_result, captured_args = nil)
      allow(Projects::Screenshots::CommitConfig).to receive(:call) do |**kwargs|
        captured_args&.replace(kwargs)
        commit_result
      end
    end

    def expect_committed_screenshot_settings(project, generated_yaml)
      expect(project.reload.screenshot_settings).to include(
        "config_path" => ".paid/custom-screenshots.yml",
        "driver" => "cuprite",
        "auto_capture" => false,
        "service_dependencies" => %w[postgres redis],
        "setup_commands" => [ "bin/setup --skip-server", "bin/rails db:prepare" ]
      )
      expect(project.screenshot_settings.dig("detection", "suggested_yaml")).to eq(generated_yaml)
    end

    it "stores the created pull request url" do
      stub_commit_config(commit_result)
      allow(Projects::Screenshots::RepoConfig).to receive(:call).and_return(repo_config_result)

      post commit_screenshot_config_project_path(project)

      expect(response).to redirect_to(edit_project_path(project, anchor: "screenshots"))
      expect(project.reload.screenshot_settings.dig("detection", "commit_pull_request_url"))
        .to eq(pull_request_url)
    end

    it "commits config generated from current submitted settings" do
      allow(Projects::Screenshots::RepoConfig).to receive(:call).and_return(repo_config_result)

      captured_args = {}
      stub_commit_config(commit_result, captured_args)

      post commit_screenshot_config_project_path(project), params: {
        project: { screenshot_settings: submitted_screenshot_settings }
      }

      expect(response).to redirect_to(edit_project_path(project, anchor: "screenshots"))
      expect(captured_args).to include(
        config_path: ".paid/custom-screenshots.yml",
        content: generated_yaml
      )
      expect_committed_screenshot_settings(project, captured_args[:content])
    end
  end

  describe "POST /projects/:project_id/screenshot_config/detect" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)

        post detect_project_screenshot_config_path(project)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as owner" do
      let(:project) { create(:project, account: account, github_token: github_token) }
      let(:result) do
        Projects::Screenshots::DetectFramework::Result.new(
          framework: "Rails",
          confidence: "high",
          driver: "cuprite",
          service_dependencies: [ "postgres" ],
          setup_commands: [ "bin/setup --skip-server", "bin/rails db:prepare" ],
          suggested_config: {
            "framework" => "Rails",
            "driver" => "cuprite",
            "auto_capture" => true,
            "services" => [ "postgres" ],
            "setup" => [ "bin/setup --skip-server", "bin/rails db:prepare" ]
          },
          suggested_yaml: <<~YAML,
            ---
            framework: Rails
            driver: cuprite
            auto_capture: true
            services:
            - postgres
            setup:
            - bin/setup --skip-server
            - bin/rails db:prepare
          YAML
          detected_at: Time.current.iso8601
        )
      end
      let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

      around do |example|
        original_cache = Rails.cache
        Rails.cache = memory_cache
        example.run
      ensure
        Rails.cache = original_cache
      end

      before do
        sign_in user
        allow(Projects::Screenshots::DetectFramework).to receive(:call).and_return(result)
      end

      it "redirects to the edit page and stores the suggested YAML in cache" do
        post detect_project_screenshot_config_path(project)

        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to include("Suggested screenshot config generated for Rails.")
        expect(flash[:screenshot_config_suggestion_cache_key]).to be_present
        expect(Rails.cache.read(flash[:screenshot_config_suggestion_cache_key])).to include("driver: cuprite")
      end

      it "returns JSON when requested" do
        post detect_project_screenshot_config_path(project), headers: { "ACCEPT" => "application/json" }

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["framework"]).to eq("Rails")
        expect(body["confidence"]).to eq("high")
        expect(body["suggested_yaml"]).to include("driver: cuprite")
        expect(body["service_dependencies"]).to eq([ "postgres" ])
      end

      context "when detection fails" do
        before do
          allow(Projects::Screenshots::DetectFramework).to receive(:call)
            .and_raise(GithubClient::ApiError.new("boom"))
        end

        it "redirects with an alert for HTML requests" do
          post detect_project_screenshot_config_path(project)

          expect(response).to redirect_to(edit_project_path(project))
          expect(flash[:alert]).to include("Could not detect screenshot config")
        end

        it "returns a JSON error for API requests" do
          post detect_project_screenshot_config_path(project), headers: { "ACCEPT" => "application/json" }

          expect(response).to have_http_status(:unprocessable_content)
          expect(JSON.parse(response.body)["error"]).to include("Could not detect screenshot config")
        end
      end
    end

    context "when authenticated as viewer" do
      let(:viewer_user) { create(:user, :viewer, account: account) }

      before { sign_in viewer_user }

      it "rejects the request" do
        project = create(:project, account: account, github_token: github_token)

        post detect_project_screenshot_config_path(project)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "DELETE /projects/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        project = create(:project, account: account, github_token: github_token)
        delete project_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      context "when user has permission" do
        # First user in account automatically gets owner role

        it "deletes the project when name confirmation matches" do
          project = create(:project, account: account, github_token: github_token)
          expect {
            delete project_path(project), params: { name_confirmation: project.name }
          }.to change(Project, :count).by(-1)
        end

        it "redirects with success message" do
          project = create(:project, account: account, github_token: github_token)
          delete project_path(project), params: { name_confirmation: project.name }
          expect(response).to redirect_to(projects_path)
          expect(flash[:notice]).to include("deleted")
        end

        it "also deletes associated agent runs" do
          project = create(:project, account: account, github_token: github_token)
          create_list(:agent_run, 3, project: project)
          expect {
            delete project_path(project), params: { name_confirmation: project.name }
          }.to change(AgentRun, :count).by(-3)
        end

        it "rejects deletion when name confirmation does not match" do
          project = create(:project, account: account, github_token: github_token)
          expect {
            delete project_path(project), params: { name_confirmation: "wrong-name" }
          }.not_to change(Project, :count)
          expect(response).to redirect_to(edit_project_path(project))
          expect(flash[:alert]).to include("does not match")
        end

        it "rejects deletion when name confirmation is missing" do
          project = create(:project, account: account, github_token: github_token)
          expect {
            delete project_path(project)
          }.not_to change(Project, :count)
          expect(response).to redirect_to(edit_project_path(project))
          expect(flash[:alert]).to include("does not match")
        end
      end

      context "when user does not have permission" do
        let(:non_owner_user) { create(:user, account: account) }

        before { sign_in non_owner_user }

        it "redirects with authorization error" do
          project = create(:project, account: account, github_token: github_token)
          delete project_path(project)
          expect(response).to redirect_to(root_path)
          expect(flash[:alert]).to include("not authorized")
        end
      end
    end
  end
end
