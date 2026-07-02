# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RunnerCredentials" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:admin_user) { create(:user, :admin, account: account) }
  let(:member_user) { create(:user, :member, account: account) }
  let(:runner) { create(:runner, user: owner_user) }

  describe "GET /runners/:runner_id/runner_credentials" do
    before { sign_in owner_user }

    it "lists runner credentials for a specific runner" do
      credential = create(:runner_credential, runner: runner, account: account, created_by: owner_user)

      get runner_runner_credentials_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Runner Credentials")
      expect(response.body).to include(runner_runner_credential_path(runner, credential))
      expect(response.body).to include("View Active Credential")
    end

    it "links to the new credential form when no credentials exist" do
      get runner_runner_credentials_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No runner credentials yet")
      expect(response.body).to include(new_runner_runner_credential_path(runner))
    end

    context "when an admin manages another user's runner" do
      before { sign_in admin_user }

      let(:runner) { create(:runner, user: admin_user) }

      it "allows access" do
        get runner_runner_credentials_path(runner)

        expect(response).to have_http_status(:ok)
      end

      it "allows managing another user's runner in the same account" do
        other_users_runner = create(:runner, user: owner_user)
        create(:runner_credential, runner: other_users_runner, account: account, created_by: owner_user)

        get runner_runner_credentials_path(other_users_runner)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Runner Credentials")
      end

      it "shows shared credentials for another runner with the same runner key in the account" do
        create(:runner_credential, runner: runner, account: account, created_by: owner_user)
        other_users_runner = create(:runner, user: owner_user, runner_key: runner.runner_key)

        get runner_runner_credentials_path(other_users_runner)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Runner Credentials")
        expect(response.body).to include("View")
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      let(:runner) { create(:runner, user: member_user) }

      it "denies access" do
        get runner_runner_credentials_path(runner)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when user is an admin" do
      before { sign_in admin_user }

      it "creates a credential for another user's runner in the same account" do
        other_users_runner = create(:runner, user: owner_user)

        expect {
          post runner_runner_credentials_path(other_users_runner), params: {
            runner_credential: {
              token: "sk-ant-oat01-admin-cross-user",
              long_lived: false
            }
          }
        }.to change(RunnerCredential, :count).by(1)

        expect(response).to redirect_to(runner_runner_credentials_path(other_users_runner))
        expect(RunnerCredential.last.created_by).to eq(admin_user)
        expect(RunnerCredential.last.auth_kind).to eq("oauth_token")
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

    it "redirects to the active credential when one already exists" do
      credential = create(:runner_credential, runner: runner, account: account, created_by: owner_user)

      get new_runner_runner_credential_path(runner)

      expect(response).to redirect_to(runner_runner_credential_path(runner, credential))
      expect(flash[:alert]).to include("already has an active credential")
    end

    context "when user is a member" do
      before { sign_in member_user }

      let(:runner) { create(:runner, user: member_user) }

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
      expect(credential.runner_key).to eq(runner.runner_key)
      expect(credential.account_id).to eq(account.id)
      expect(credential.long_lived).to be true
      expect(credential.auth_kind).to eq("oauth_token")
      expect(credential.name).to include(runner.display_name)
      expect(credential.created_by_id).to eq(owner_user.id)
    end

    it "redirects to the active credential instead of raising a duplicate validation error" do
      credential = create(:runner_credential, runner: runner, account: account, created_by: owner_user)

      expect {
        post runner_runner_credentials_path(runner), params: {
          runner_credential: {
            token: "sk-ant-oat01-replacement",
            long_lived: true
          }
        }
      }.not_to change(RunnerCredential, :count)

      expect(response).to redirect_to(runner_runner_credential_path(runner, credential))
      expect(flash[:alert]).to include("already has an active credential")
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

      let(:runner) { create(:runner, user: member_user) }

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
      get runner_runner_credential_path(runner, credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Runner Credential")
      expect(response.body).to include(Runner.display_name_for(runner.runner_key))
    end

    context "when user is a member" do
      before { sign_in member_user }

      let(:runner) { create(:runner, user: member_user) }
      let(:credential) { create(:runner_credential, runner: runner, account: account, created_by: owner_user) }

      it "denies access" do
        get runner_runner_credential_path(runner, credential)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /runners/:runner_id/runner_credentials/:id" do
    let(:credential) { create(:runner_credential, runner: runner, account: account, created_by: owner_user) }

    before { sign_in owner_user }

    it "revokes a runner credential" do
      delete runner_runner_credential_path(runner, credential)

      expect(response).to redirect_to(runner_runner_credentials_path(runner))
      expect(flash[:notice]).to include("successfully revoked")

      credential.reload
      expect(credential).to be_revoked
    end

    context "when user is a member" do
      before { sign_in member_user }

      let(:runner) { create(:runner, user: member_user) }
      let(:credential) { create(:runner_credential, runner: runner, account: account, created_by: owner_user) }

      it "denies access" do
        delete runner_runner_credential_path(runner, credential)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
