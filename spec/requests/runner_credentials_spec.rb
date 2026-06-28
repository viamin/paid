# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RunnerCredentials" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:admin_user) { create(:user, :admin, account: account) }
  let(:member_user) { create(:user, :member, account: account) }
  let(:runner) { create(:runner, account: account) }

  describe "GET /runners/:runner_id/runner_credentials" do
    before { sign_in owner_user }

    it "lists runner credentials for a specific runner" do
      create(:runner_credential, runner: runner, account: account, created_by: owner_user)

      get runner_runner_credentials_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Runner Credentials")
    end

    context "when user is an admin" do
      before { sign_in admin_user }

      it "allows access" do
        get runner_runner_credentials_path(runner)

        expect(response).to have_http_status(:ok)
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        get runner_runner_credentials_path(runner)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /runners/:runner_id/runner_credentials/new" do
    before { sign_in owner_user }

    it "renders the new credential form" do
      get new_runner_runner_credential_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add Runner Credential")
      expect(response.body).to include("Setup Token")
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        get new_runner_runner_credential_path(runner)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /runners/:runner_id/runner_credentials" do
    before { sign_in owner_user }

    it "creates a runner credential" do
      expect {
        post runner_runner_credentials_path(runner), params: {
          runner_credential: {
            token: "sk-ant-oat01-test123",
            long_lived: true
          }
        }
      }.to change(RunnerCredential, :count).by(1)

      expect(response).to redirect_to(runner_runner_credentials_path(runner))
      expect(flash[:notice]).to include("Runner credential saved")

      credential = RunnerCredential.last
      expect(credential.runner_id).to eq(runner.id)
      expect(credential.account_id).to eq(account.id)
      expect(credential.long_lived).to be true
      expect(credential.created_by_id).to eq(owner_user.id)
    end

    it "requires a token" do
      post runner_runner_credentials_path(runner), params: {
        runner_credential: {
          token: "",
          long_lived: false
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("can&#39;t be blank")
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        post runner_runner_credentials_path(runner), params: {
          runner_credential: {
            token: "sk-ant-oat01-test123",
            long_lived: true
          }
        }

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /runners/:runner_id/runner_credentials/:id" do
    let(:credential) { create(:runner_credential, runner: runner, account: account, created_by: owner_user) }

    before { sign_in owner_user }

    it "shows a runner credential" do
      get runner_credential_path(runner, credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Runner Credential")
      expect(response.body).to include(runner.display_name)
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        get runner_credential_path(runner, credential)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "DELETE /runners/:runner_id/runner_credentials/:id" do
    let(:credential) { create(:runner_credential, runner: runner, account: account, created_by: owner_user) }

    before { sign_in owner_user }

    it "revokes a runner credential" do
      delete runner_credential_path(runner, credential)

      expect(response).to redirect_to(runner_runner_credentials_path(runner))
      expect(flash[:notice]).to include("successfully revoked")

      credential.reload
      expect(credential).to be_revoked
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        delete runner_credential_path(runner, credential)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
