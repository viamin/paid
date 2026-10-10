# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PersonalAccessTokens" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /personal_access_tokens" do
    # @spec MOBILE-API-001
    it "redirects to the sign in page when not authenticated" do
      get personal_access_tokens_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it "renders the index page for a signed-in user" do
      sign_in user
      get personal_access_tokens_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Personal Access Tokens")
    end

    it "lists the user's tokens with name, created, last used, and status" do
      plaintext, token = create_token_for(user, name: "iPhone", last_used_at: 1.hour.ago)
      sign_in user
      get personal_access_tokens_path

      expect(response.body).to include("iPhone")
      expect(response.body).to include("Never").or include("ago")
      expect(response.body).to include("Active")
      expect(response.body).not_to include(plaintext)
    end

    it "does not list other users' tokens within the same account" do
      colleague = create(:user, account: account)
      create_token_for(colleague, name: "Colleague Phone")

      sign_in user
      get personal_access_tokens_path

      expect(response.body).not_to include("Colleague Phone")
    end

    it "does not list tokens from other accounts" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      create_token_for(other_user, name: "Other Account Phone")

      sign_in user
      get personal_access_tokens_path

      expect(response.body).not_to include("Other Account Phone")
    end
  end

  describe "POST /personal_access_tokens" do
    # @spec MOBILE-API-001
    it "redirects to the sign in page when not authenticated" do
      post personal_access_tokens_path, params: { personal_access_token: { name: "iPhone" } }

      expect(response).to redirect_to(new_user_session_path)
    end

    it "creates the token and shows the plaintext exactly once" do
      sign_in user
      post personal_access_tokens_path, params: { personal_access_token: { name: "iPhone" } }

      expect(response).to have_http_status(:created)
      token = PersonalAccessToken.find_by!(name: "iPhone")
      expect(token.user).to eq(user)
      expect(token.account).to eq(account)
      expect(token).to be_active

      plaintext = extract_created_plaintext(response.body)
      expect(plaintext).to start_with("paid_pat_")
      expect(token.token_digest).to eq(PersonalAccessToken.digest(plaintext))
    end

    it "stores only the digest — the plaintext is never re-rendered" do
      sign_in user
      post personal_access_tokens_path, params: { personal_access_token: { name: "iPhone" } }

      plaintext = extract_created_plaintext(response.body)

      get personal_access_tokens_path
      expect(response.body).not_to include(plaintext)
    end

    it "re-renders the form when the name is missing" do
      sign_in user
      post personal_access_tokens_path, params: { personal_access_token: { name: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("New Personal Access Token")
    end

    it "re-renders the form when the name is already taken by the user" do
      create_token_for(user, name: "iPhone")
      sign_in user

      post personal_access_tokens_path, params: { personal_access_token: { name: "iPhone" } }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /personal_access_tokens/:id" do
    # @spec MOBILE-API-001
    it "revokes the token and redirects to the index" do
      _, token = create_token_for(user, name: "iPhone")
      sign_in user

      expect {
        delete personal_access_token_path(token)
      }.to change { token.reload.revoked_at }.from(nil).to(be_present)

      expect(response).to redirect_to(personal_access_tokens_path)
    end

    it "marks the token as revoked in the listing" do
      _, token = create_token_for(user, name: "iPhone")
      token.revoke!
      sign_in user

      get personal_access_tokens_path

      expect(response.body).to include("Revoked")
    end

    it "cannot revoke another user's token" do
      colleague = create(:user, account: account)
      _, token = create_token_for(colleague, name: "Colleague Phone")
      sign_in user

      delete personal_access_token_path(token)

      # The policy scope hides the token entirely — same 404 as a nonexistent id.
      expect(response).to have_http_status(:not_found)
      expect(token.reload.revoked_at).to be_nil
    end
  end

  describe "revocation use-through" do
    it "round-trips: create → use → last_used_at set → revoke → 401" do
      # @spec MOBILE-API-001
      sign_in user
      post personal_access_tokens_path, params: { personal_access_token: { name: "iPhone" } }
      plaintext = extract_created_plaintext(response.body)
      token = PersonalAccessToken.find_by!(name: "iPhone")

      get "/api/v1/probe", headers: { "Authorization" => "Bearer #{plaintext}" }
      expect(response).to have_http_status(:ok)
      expect(token.reload.last_used_at).to be_present

      token.revoke!
      get "/api/v1/probe", headers: { "Authorization" => "Bearer #{plaintext}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  private

  def create_token_for(owner, name:, last_used_at: nil)
    plaintext = PersonalAccessToken.generate_plaintext
    token = create(:personal_access_token, user: owner, name: name, plaintext: plaintext, last_used_at: last_used_at)
    [ plaintext, token ]
  end

  def extract_created_plaintext(body)
    body[/paid_pat_[A-Za-z0-9_-]+/]
  end
end
