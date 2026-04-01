# frozen_string_literal: true

require "rails_helper"

RSpec.describe "UserPreCommitRequirements" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /user_pre_commit_requirements" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get user_pre_commit_requirements_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists user-level requirements" do
        create(:pre_commit_requirement, account: account, user: user, name: "my-lint")
        get user_pre_commit_requirements_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /user_pre_commit_requirements" do
    let(:valid_params) do
      {
        pre_commit_requirement: {
          name: "my-lint", command: "bin/lint", check_type: "shell_command",
          failure_behavior: "block", position: 0
        }
      }
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        post user_pre_commit_requirements_path, params: valid_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as any role" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "creates a user-level pre-commit requirement" do
        expect {
          post user_pre_commit_requirements_path, params: valid_params
        }.to change(PreCommitRequirement, :count).by(1)

        expect(response).to redirect_to(user_pre_commit_requirements_path)
        req = PreCommitRequirement.last
        expect(req.name).to eq("my-lint")
        expect(req.user).to eq(member)
        expect(req.account).to eq(account)
        expect(req).to be_user_level
      end
    end
  end

  describe "PATCH /user_pre_commit_requirements/:id" do
    let!(:requirement) do
      create(:pre_commit_requirement, account: account, user: user, name: "my-lint")
    end

    context "when authenticated as owning user" do
      before { sign_in user }

      it "updates the requirement" do
        patch user_pre_commit_requirement_path(requirement),
          params: { pre_commit_requirement: { name: "updated-lint" } }

        expect(response).to redirect_to(user_pre_commit_requirements_path)
        expect(requirement.reload.name).to eq("updated-lint")
      end
    end

    context "when authenticated as a different user" do
      let(:other_user) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in other_user
      end

      it "returns not found for another user's requirement" do
        patch user_pre_commit_requirement_path(requirement),
          params: { pre_commit_requirement: { name: "hacked" } }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /user_pre_commit_requirements/:id" do
    let!(:requirement) do
      create(:pre_commit_requirement, account: account, user: user, name: "my-lint")
    end

    context "when authenticated as owning user" do
      before { sign_in user }

      it "destroys the requirement" do
        expect {
          delete user_pre_commit_requirement_path(requirement)
        }.to change(PreCommitRequirement, :count).by(-1)

        expect(response).to redirect_to(user_pre_commit_requirements_path)
      end
    end
  end
end
