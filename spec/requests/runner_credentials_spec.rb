# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RunnerCredentials" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:admin_user) { create(:user, :admin, account: account) }
  let(:member_user) { create(:user, :member, account: account) }

  describe "GET /runner_credentials" do
    before { sign_in owner_user }

    it "lists the account's runner credentials" do
      matching = create(:runner_credential, account: account, created_by: owner_user, name: "Claude Long-Lived")
      create(:runner_credential, :revoked, account: account, created_by: owner_user, name: "Old Token")

      get runner_credentials_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(matching.name)
      expect(response.body).to include("Old Token")
    end

    context "when user is an admin" do
      before { sign_in admin_user }

      it "allows access" do
        get runner_credentials_path

        expect(response).to have_http_status(:ok)
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        get runner_credentials_path

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /runner_credentials/new" do
    before { sign_in owner_user }

    it "renders the new credential form" do
      get new_runner_credential_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add Runner Credential")
      expect(response.body).to include("setup-token")
    end

    it "prefills the runner key from query params" do
      get new_runner_credential_path(runner_key: "claude")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Claude")
    end

    context "when user is an admin" do
      before { sign_in admin_user }

      it "allows access" do
        get new_runner_credential_path

        expect(response).to have_http_status(:ok)
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        get new_runner_credential_path

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /runner_credentials" do
    before { sign_in owner_user }

    it "creates a long-lived runner credential" do
      post runner_credentials_path, params: {
        runner_credential: {
          name: "Claude Setup Token",
          runner_key: "claude",
          token: "sk-ant-oat01-secret",
          long_lived: "1"
        }
      }

      credential = RunnerCredential.last
      expect(response).to redirect_to(runner_credential_path(credential))
      expect(credential.name).to eq("Claude Setup Token")
      expect(credential.runner_key).to eq("claude")
      expect(credential.token).to eq("sk-ant-oat01-secret")
      expect(credential).to be_long_lived
      expect(credential.auth_kind).to eq("oauth_token")
      expect(credential.created_by).to eq(owner_user)
    end

    it "re-renders new on validation failure" do
      post runner_credentials_path, params: {
        runner_credential: {
          name: "",
          runner_key: "claude",
          token: ""
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Add Runner Credential")
    end

    context "when user is an admin" do
      before { sign_in admin_user }

      it "creates a credential" do
        post runner_credentials_path, params: {
          runner_credential: {
            name: "Admin Token",
            runner_key: "claude",
            token: "sk-ant-oat01-admin",
            long_lived: "1"
          }
        }

        expect(RunnerCredential.last.name).to eq("Admin Token")
        expect(response).to redirect_to(runner_credential_path(RunnerCredential.last))
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        post runner_credentials_path, params: {
          runner_credential: {
            name: "Test",
            runner_key: "claude",
            token: "sk-ant-oat01-test"
          }
        }

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /runner_credentials/:id" do
    before { sign_in owner_user }

    it "shows the credential details without the token" do
      credential = create(:runner_credential, account: account, created_by: owner_user, name: "My Token", token: "sk-ant-oat01-visible")

      get runner_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("My Token")
      expect(response.body).not_to include("sk-ant-oat01-visible")
    end

    context "when user is an admin" do
      before { sign_in admin_user }

      it "shows the credential" do
        credential = create(:runner_credential, account: account, created_by: owner_user, name: "Admin Visible")

        get runner_credential_path(credential)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Admin Visible")
      end
    end

    it "does not show credentials from other accounts" do
      other_account = create(:account)
      other_credential = create(:runner_credential, account: other_account)

      get runner_credential_path(other_credential)

      expect(response).to have_http_status(:not_found)
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        credential = create(:runner_credential, account: account, created_by: owner_user, name: "My Token")

        get runner_credential_path(credential)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /runner_credentials/:id" do
    context "when user has owner role" do
      before { sign_in owner_user }

      it "revokes the credential and redirects to index" do
        credential = create(:runner_credential, account: account, created_by: owner_user)

        delete runner_credential_path(credential)

        expect(credential.reload).to be_revoked
        expect(response).to redirect_to(runner_credentials_path)
        follow_redirect!
        expect(response.body).to include("deactivated")
      end
    end

    context "when user has admin role" do
      before { sign_in admin_user }

      it "revokes the credential" do
        credential = create(:runner_credential, account: account, created_by: owner_user)

        delete runner_credential_path(credential)

        expect(credential.reload).to be_revoked
        expect(response).to redirect_to(runner_credentials_path)
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        credential = create(:runner_credential, account: account, created_by: owner_user)

        delete runner_credential_path(credential)

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when credential belongs to another account" do
      before { sign_in owner_user }

      it "is not accessible" do
        other_account = create(:account)
        other_credential = create(:runner_credential, account: other_account)

        delete runner_credential_path(other_credential)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
