# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AccountPreCommitRequirements" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /account_pre_commit_requirements" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get account_pre_commit_requirements_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists account-level requirements" do
        create(:pre_commit_requirement, account: account, name: "lint")
        get account_pre_commit_requirements_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /account_pre_commit_requirements" do
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
        post account_pre_commit_requirements_path, params: valid_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "creates an account-level pre-commit requirement" do
        expect {
          post account_pre_commit_requirements_path, params: valid_params
        }.to change(PreCommitRequirement, :count).by(1)

        expect(response).to redirect_to(account_pre_commit_requirements_path)
        req = PreCommitRequirement.last
        expect(req.name).to eq("lint")
        expect(req.account).to eq(account)
        expect(req).to be_account_level
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        post account_pre_commit_requirements_path, params: valid_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "PATCH /account_pre_commit_requirements/:id" do
    let!(:requirement) do
      create(:pre_commit_requirement, account: account, name: "lint")
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "updates the requirement" do
        patch account_pre_commit_requirement_path(requirement),
          params: { pre_commit_requirement: { name: "updated-lint" } }

        expect(response).to redirect_to(account_pre_commit_requirements_path)
        expect(requirement.reload.name).to eq("updated-lint")
      end
    end
  end

  describe "DELETE /account_pre_commit_requirements/:id" do
    let!(:requirement) do
      create(:pre_commit_requirement, account: account, name: "lint")
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "destroys the requirement" do
        expect {
          delete account_pre_commit_requirement_path(requirement)
        }.to change(PreCommitRequirement, :count).by(-1)

        expect(response).to redirect_to(account_pre_commit_requirements_path)
      end
    end
  end
end
