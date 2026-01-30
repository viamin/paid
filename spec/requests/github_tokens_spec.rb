# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "GithubTokens" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /github_tokens" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get github_tokens_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get github_tokens_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("GitHub Tokens")
      end

      it "shows the user's tokens" do
        token = create(:github_token, account: account, name: "My Token")
        get github_tokens_path
        expect(response.body).to include("My Token")
      end

      it "does not show tokens from other accounts" do
        other_account = create(:account)
        create(:github_token, account: other_account, name: "Other Token")
        get github_tokens_path
        expect(response.body).not_to include("Other Token")
      end

      it "shows status indicators for active tokens" do
        create(:github_token, account: account, name: "Active Token")
        get github_tokens_path
        expect(response.body).to include("Active")
      end

      it "shows status indicators for expired tokens" do
        create(:github_token, :expired, account: account, name: "Expired Token")
        get github_tokens_path
        expect(response.body).to include("Expired")
      end

      it "shows status indicators for revoked tokens" do
        create(:github_token, :revoked, account: account, name: "Revoked Token")
        get github_tokens_path
        expect(response.body).to include("Revoked")
      end

      it "shows expiring soon warning for tokens expiring within 7 days" do
        create(:github_token, :expiring_soon, account: account, name: "Expiring Token")
        get github_tokens_path
        expect(response.body).to include("Expiring Soon")
      end
    end
  end

  describe "GET /github_tokens/new" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get new_github_token_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the new token form" do
        get new_github_token_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Add GitHub Token")
      end

      it "displays permission guidance" do
        get new_github_token_path
        expect(response.body).to include("Required Permissions")
        expect(response.body).to include("Contents:")
        expect(response.body).to include("Issues:")
        expect(response.body).to include("Pull requests:")
        expect(response.body).to include("Metadata:")
      end

      it "includes a link to create a new GitHub token" do
        get new_github_token_path
        expect(response.body).to include("github.com/settings/tokens")
      end
    end
  end

  describe "POST /github_tokens" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post github_tokens_path, params: { github_token: { name: "Test", token: "ghp_#{'a' * 36}" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      context "with valid parameters" do
        let(:valid_token) { "ghp_#{'a' * 36}" }
        let(:github_user_response) do
          {
            login: "testuser",
            id: 12345,
            name: "Test User",
            email: "test@example.com"
          }
        end

        before do
          octokit_client = instance_double(Octokit::Client)
          allow(Octokit::Client).to receive(:new).and_return(octokit_client)
          allow(octokit_client).to receive_messages(user: OpenStruct.new(github_user_response), scopes: [ "repo", "read:org" ])
          allow(octokit_client).to receive(:middleware=)
        end

        it "creates a new token" do
          expect {
            post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          }.to change(GithubToken, :count).by(1)
        end

        it "redirects to the token show page with success message" do
          post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          expect(response).to redirect_to(github_token_path(GithubToken.last))
          expect(flash[:notice]).to include("successfully added")
          expect(flash[:notice]).to include("testuser")
        end

        it "associates the token with the current account" do
          post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          expect(GithubToken.last.account).to eq(account)
        end

        it "associates the token with the current user as creator" do
          post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          expect(GithubToken.last.created_by).to eq(user)
        end
      end

      context "with invalid token format" do
        it "re-renders the form with errors" do
          post github_tokens_path, params: { github_token: { name: "Test Token", token: "invalid" } }
          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).to include("must be a valid GitHub token format")
        end
      end

      context "with missing name" do
        it "re-renders the form with errors" do
          post github_tokens_path, params: { github_token: { name: "", token: "ghp_#{'a' * 36}" } }
          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).to include("can&#39;t be blank")
        end
      end

      context "when GitHub API returns authentication error" do
        let(:valid_token) { "ghp_#{'a' * 36}" }

        before do
          octokit_client = instance_double(Octokit::Client)
          allow(Octokit::Client).to receive(:new).and_return(octokit_client)
          allow(octokit_client).to receive(:middleware=)
          allow(octokit_client).to receive(:user).and_raise(Octokit::Unauthorized.new({}))
        end

        it "re-renders the form with error message" do
          post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.body).to include("invalid or has been revoked")
        end

        it "does not create the token" do
          expect {
            post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          }.not_to change(GithubToken, :count)
        end
      end
    end
  end

  describe "GET /github_tokens/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        token = create(:github_token, account: account)
        get github_token_path(token)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows the token details" do
        token = create(:github_token, account: account, name: "My Token")
        get github_token_path(token)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("My Token")
      end

      it "masks the token value" do
        token = create(:github_token, account: account)
        get github_token_path(token)
        expect(response.body).to include("****")
        expect(response.body).not_to include(token.token[9...-5])
      end

      it "shows scopes" do
        token = create(:github_token, account: account, scopes: [ "repo", "read:org" ])
        get github_token_path(token)
        expect(response.body).to include("repo")
        expect(response.body).to include("read:org")
      end

      it "shows expiration warning for tokens expiring soon" do
        token = create(:github_token, :expiring_soon, account: account)
        get github_token_path(token)
        expect(response.body).to include("Token Expiring Soon")
      end

      it "does not allow viewing tokens from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        get github_token_path(other_token)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /github_tokens/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        token = create(:github_token, account: account)
        delete github_token_path(token)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      context "when user has permission" do
        before do
          user.add_role(:owner, account)
        end

        it "revokes the token" do
          token = create(:github_token, account: account)
          expect {
            delete github_token_path(token)
          }.to change { token.reload.revoked? }.from(false).to(true)
        end

        it "redirects with success message" do
          token = create(:github_token, account: account)
          delete github_token_path(token)
          expect(response).to redirect_to(github_tokens_path)
          expect(flash[:notice]).to include("deactivated")
        end
      end

      context "when user does not have permission" do
        # Create a second user who won't have owner role (first user gets owner automatically)
        let(:non_owner_user) { create(:user, account: account) }

        before { sign_in non_owner_user }

        it "redirects with authorization error" do
          token = create(:github_token, account: account)
          delete github_token_path(token)
          expect(response).to redirect_to(root_path)
          expect(flash[:alert]).to include("not authorized")
        end
      end
    end
  end
end
