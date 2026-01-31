# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "Projects" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }

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
        expect(response.body).to include("Repository Owner")
        expect(response.body).to include("Repository Name")
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
          expect(response).to have_http_status(:unprocessable_entity)
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
          expect(response).to have_http_status(:unprocessable_entity)
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
          expect(response).to have_http_status(:unprocessable_entity)
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
          expect(response).to have_http_status(:unprocessable_entity)
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
          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).to include("must belong to the same account")
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
        expect(response.body).to include("Total Runs")
        expect(response.body).to include("Completed")
        expect(response.body).to include("$15.00")
      end

      it "shows recent agent runs" do
        project = create(:project, account: account, github_token: github_token)
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed")
        get project_path(project)
        expect(response.body).to include("Recent Agent Runs")
        expect(response.body).to include("Claude Code")
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
      before { sign_in user }

      it "shows the edit form" do
        project = create(:project, account: account, github_token: github_token, name: "My Project")
        get edit_project_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Edit Project")
        expect(response.body).to include("My Project")
      end

      it "shows the repository name (not editable)" do
        project = create(:project, account: account, github_token: github_token, owner: "octocat", repo: "hello")
        get edit_project_path(project)
        expect(response.body).to include("octocat/hello")
        expect(response.body).to include("cannot be changed")
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
      before { sign_in user }

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
        expect(response).to have_http_status(:unprocessable_entity)
        expect(project.reload.github_token).to eq(github_token)
      end

      context "with invalid parameters" do
        it "re-renders the form with errors" do
          project = create(:project, account: account, github_token: github_token)
          patch project_path(project), params: { project: { poll_interval_seconds: 30 } }
          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).to include("greater than or equal to 60")
        end
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

        it "deletes the project" do
          project = create(:project, account: account, github_token: github_token)
          expect {
            delete project_path(project)
          }.to change(Project, :count).by(-1)
        end

        it "redirects with success message" do
          project = create(:project, account: account, github_token: github_token)
          delete project_path(project)
          expect(response).to redirect_to(projects_path)
          expect(flash[:notice]).to include("deleted")
        end

        it "also deletes associated agent runs" do
          project = create(:project, account: account, github_token: github_token)
          create_list(:agent_run, 3, project: project)
          expect {
            delete project_path(project)
          }.to change(AgentRun, :count).by(-3)
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
