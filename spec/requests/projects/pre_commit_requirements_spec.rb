# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::PreCommitRequirements" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "POST /projects/:project_id/pre_commit_requirements" do
    let(:valid_params) do
      {
        pre_commit_requirement: {
          name: "lint", command: "bin/lint", check_type: "shell_command",
          failure_behavior: "block", position: 0
        }
      }
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        post project_pre_commit_requirements_path(project), params: valid_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "creates a pre-commit requirement" do
        expect {
          post project_pre_commit_requirements_path(project), params: valid_params
        }.to change(PreCommitRequirement, :count).by(1)

        expect(response).to redirect_to(project_pre_commit_requirements_path(project))
        req = project.pre_commit_requirements.last
        expect(req.name).to eq("lint")
        expect(req.account).to eq(account)
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        post project_pre_commit_requirements_path(project), params: valid_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in viewer
      end

      it "redirects with authorization error" do
        post project_pre_commit_requirements_path(project), params: valid_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "PATCH /projects/:project_id/pre_commit_requirements/:id" do
    let!(:requirement) do
      create(:pre_commit_requirement, account: account, project: project, name: "lint")
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        patch project_pre_commit_requirement_path(project, requirement),
          params: { pre_commit_requirement: { name: "updated-lint" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "updates the requirement" do
        patch project_pre_commit_requirement_path(project, requirement),
          params: { pre_commit_requirement: { name: "updated-lint" } }

        expect(response).to redirect_to(project_pre_commit_requirements_path(project))
        expect(requirement.reload.name).to eq("updated-lint")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        patch project_pre_commit_requirement_path(project, requirement),
          params: { pre_commit_requirement: { name: "hacked" } }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "DELETE /projects/:project_id/pre_commit_requirements/:id" do
    let!(:requirement) do
      create(:pre_commit_requirement, account: account, project: project, name: "lint")
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        delete project_pre_commit_requirement_path(project, requirement)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "destroys the requirement" do
        expect {
          delete project_pre_commit_requirement_path(project, requirement)
        }.to change(PreCommitRequirement, :count).by(-1)

        expect(response).to redirect_to(project_pre_commit_requirements_path(project))
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        delete project_pre_commit_requirement_path(project, requirement)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
