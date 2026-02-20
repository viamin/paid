# frozen_string_literal: true

require "rails_helper"

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
        create(:github_token, account: account, name: "My Token")
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
        create(:github_token, account: account, name: "Expiring Token", expires_at: 6.days.from_now)
        get github_tokens_path
        expect(response.body).to include("Expiring Soon")
      end

      it "shows validating status for pending tokens" do
        create(:github_token, :pending_validation, account: account, name: "Pending Token")
        get github_tokens_path
        expect(response.body).to include("Validating...")
      end

      it "shows validation failed status" do
        create(:github_token, :validation_failed, account: account, name: "Failed Token")
        get github_tokens_path
        expect(response.body).to include("Validation Failed")
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

        it "creates a new token" do
          expect {
            post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          }.to change(GithubToken, :count).by(1)
        end

        it "creates token with pending validation status" do
          post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          expect(GithubToken.last.validation_status).to eq("pending")
        end

        it "enqueues a validation job" do
          expect {
            post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          }.to have_enqueued_job(GithubTokenValidationJob)
        end

        it "redirects to the token show page" do
          post github_tokens_path, params: { github_token: { name: "Test Token", token: valid_token } }
          expect(response).to redirect_to(github_token_path(GithubToken.last))
          expect(flash[:notice]).to include("Validating")
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
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("must be a valid GitHub token format")
        end
      end

      context "with missing name" do
        it "re-renders the form with errors" do
          post github_tokens_path, params: { github_token: { name: "", token: "ghp_#{'a' * 36}" } }
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("can&#39;t be blank")
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
        token = create(:github_token, account: account, expires_at: 6.days.from_now)
        get github_token_path(token)
        expect(response.body).to include("Token Expiring Soon")
      end

      it "does not allow viewing tokens from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        get github_token_path(other_token)
        expect(response).to have_http_status(:not_found)
      end

      it "shows validating status for pending tokens" do
        token = create(:github_token, :pending_validation, account: account)
        get github_token_path(token)
        expect(response.body).to include("Validating...")
      end

      it "shows validation failed badge for failed tokens" do
        token = create(:github_token, :validation_failed, account: account)
        get github_token_path(token)
        expect(response.body).to include("Validation Failed")
      end
    end
  end

  describe "GET /github_tokens/:id/validation_status" do
    context "when authenticated" do
      before { sign_in user }

      it "shows validating state for pending tokens" do
        token = create(:github_token, :pending_validation, account: account)
        get validation_status_github_token_path(token)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Validating token with GitHub")
      end

      it "shows success state for validated tokens" do
        token = create(:github_token, account: account, accessible_repositories: [ { "id" => 1, "full_name" => "owner/repo" } ])
        get validation_status_github_token_path(token)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("validated successfully")
      end

      it "shows error state for failed tokens" do
        token = create(:github_token, :validation_failed, account: account)
        get validation_status_github_token_path(token)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Validation Failed")
        expect(response.body).to include("Retry Validation")
      end
    end
  end

  describe "POST /github_tokens/:id/retry_validation" do
    context "when authenticated" do
      before { sign_in user }

      it "resets validation status and enqueues job" do
        token = create(:github_token, :validation_failed, account: account)
        expect {
          post retry_validation_github_token_path(token)
        }.to have_enqueued_job(GithubTokenValidationJob)
        expect(token.reload.validation_status).to eq("pending")
        expect(response).to redirect_to(github_token_path(token))
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
        # First user in account automatically gets owner role via User#assign_owner_role_if_first_user

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
