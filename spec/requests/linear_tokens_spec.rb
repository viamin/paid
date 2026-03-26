# frozen_string_literal: true

require "rails_helper"

RSpec.describe "LinearTokens" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /linear_tokens" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get linear_tokens_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get linear_tokens_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Linear API Keys")
      end

      it "shows the user's tokens" do
        create(:linear_token, account: account, name: "My Linear Key")
        get linear_tokens_path
        expect(response.body).to include("My Linear Key")
      end

      it "does not show tokens from other accounts" do
        other_account = create(:account)
        create(:linear_token, account: other_account, name: "Other Key")
        get linear_tokens_path
        expect(response.body).not_to include("Other Key")
      end

      it "shows status indicators for active tokens" do
        create(:linear_token, account: account)
        get linear_tokens_path
        expect(response.body).to include("Active")
      end

      it "shows status indicators for revoked tokens" do
        create(:linear_token, :revoked, account: account)
        get linear_tokens_path
        expect(response.body).to include("Revoked")
      end
    end
  end

  describe "GET /linear_tokens/new" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get new_linear_token_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the new token form" do
        get new_linear_token_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Add Linear API Key")
      end
    end
  end

  describe "POST /linear_tokens" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post linear_tokens_path, params: { linear_token: { name: "Test", token: "lin_api_#{'a' * 32}" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      context "with valid parameters" do
        let(:valid_token) { "lin_api_#{'a' * 32}" }

        it "creates a new token" do
          expect {
            post linear_tokens_path, params: { linear_token: { name: "Test Key", token: valid_token } }
          }.to change(LinearToken, :count).by(1)
        end

        it "redirects to the token show page" do
          post linear_tokens_path, params: { linear_token: { name: "Test Key", token: valid_token } }
          expect(response).to redirect_to(linear_token_path(LinearToken.last))
        end

        it "associates the token with the current account" do
          post linear_tokens_path, params: { linear_token: { name: "Test Key", token: valid_token } }
          expect(LinearToken.last.account).to eq(account)
        end

        it "associates the token with the current user as creator" do
          post linear_tokens_path, params: { linear_token: { name: "Test Key", token: valid_token } }
          expect(LinearToken.last.created_by).to eq(user)
        end
      end

      context "with invalid token format" do
        it "re-renders the form with errors" do
          post linear_tokens_path, params: { linear_token: { name: "Test Key", token: "invalid" } }
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("must be a valid Linear API key format")
        end
      end

      context "with missing name" do
        it "re-renders the form with errors" do
          post linear_tokens_path, params: { linear_token: { name: "", token: "lin_api_#{'a' * 32}" } }
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("can&#39;t be blank")
        end
      end
    end
  end

  describe "GET /linear_tokens/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        token = create(:linear_token, account: account)
        get linear_token_path(token)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows the token details" do
        token = create(:linear_token, account: account, name: "My Key")
        get linear_token_path(token)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("My Key")
      end

      it "masks the token value" do
        token = create(:linear_token, account: account)
        get linear_token_path(token)
        expect(response.body).to include("****")
      end

      it "does not allow viewing tokens from other accounts" do
        other_account = create(:account)
        other_token = create(:linear_token, account: other_account)
        get linear_token_path(other_token)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /linear_tokens/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        token = create(:linear_token, account: account)
        delete linear_token_path(token)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      context "when user has permission" do
        it "revokes the token" do
          token = create(:linear_token, account: account)
          expect {
            delete linear_token_path(token)
          }.to change { token.reload.revoked? }.from(false).to(true)
        end

        it "redirects with success message" do
          token = create(:linear_token, account: account)
          delete linear_token_path(token)
          expect(response).to redirect_to(linear_tokens_path)
          expect(flash[:notice]).to include("deactivated")
        end
      end

      context "when user does not have permission" do
        let(:non_owner_user) { create(:user, account: account) }

        before { sign_in non_owner_user }

        it "redirects with authorization error" do
          token = create(:linear_token, account: account)
          delete linear_token_path(token)
          expect(response).to redirect_to(root_path)
          expect(flash[:alert]).to include("not authorized")
        end
      end
    end
  end
end
