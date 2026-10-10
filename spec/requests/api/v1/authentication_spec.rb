# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 bearer authentication" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let!(:token) do
    create(:personal_access_token, user: user, name: "iPhone", plaintext: plaintext)
  end
  let(:auth_headers) { { "Authorization" => "Bearer #{plaintext}" } }

  describe "GET /api/v1/probe with a valid bearer token" do
    it "authenticates without a Devise session" do
      # @spec MOBILE-API-005
      get "/api/v1/probe", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "user_id" => user.id,
        "account_id" => account.id
      )
    end

    it "establishes the tenant context from the token's account" do
      # @spec MOBILE-API-005
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_plaintext = PersonalAccessToken.generate_plaintext
      create(:personal_access_token, user: other_user, account: other_account, name: "iPad", plaintext: other_plaintext)

      get "/api/v1/probe", headers: { "Authorization" => "Bearer #{other_plaintext}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["account_id"]).to eq(other_account.id)
    end

    it "resolves the current user so Pundit policies see the same subject as the web session path" do
      # @spec MOBILE-API-005
      get "/api/v1/probe", headers: auth_headers

      expect(response.parsed_body["user_id"]).to eq(user.id)
    end

    it "stamps the throttled last_used_at on the token" do
      # @spec MOBILE-API-003
      expect { get "/api/v1/probe", headers: auth_headers }
        .to change { token.reload.last_used_at }.from(nil).to(be_present)
    end

    it "does not rewrite last_used_at on an immediately following request" do
      # @spec MOBILE-API-003
      get "/api/v1/probe", headers: auth_headers
      stamped_at = token.reload.last_used_at

      get "/api/v1/probe", headers: auth_headers

      expect(token.reload.last_used_at).to eq(stamped_at)
    end
  end

  describe "rejected bearers" do
    it "returns 401 with the unified error envelope when the header is missing" do
      # @spec MOBILE-API-002
      get "/api/v1/probe"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to match(
        "error" => {
          "code" => "unauthorized",
          "message" => be_a(String),
          "details" => {}
        }
      )
    end

    it "returns 401 for a malformed Authorization header" do
      # @spec MOBILE-API-002
      [ "Token #{plaintext}", "Bearer", "Basic abc123", plaintext ].each do |header|
        get "/api/v1/probe", headers: { "Authorization" => header }

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
      end
    end

    it "returns 401 for an unknown secret" do
      # @spec MOBILE-API-002
      get "/api/v1/probe", headers: { "Authorization" => "Bearer paid_pat_#{SecureRandom.urlsafe_base64(32)}" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for a revoked token" do
      # @spec MOBILE-API-002
      token.revoke!

      get "/api/v1/probe", headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for an expired token" do
      # @spec MOBILE-API-002
      token.update!(expires_at: 1.minute.ago)

      get "/api/v1/probe", headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
    end

    it "uses one generic message across every failure case" do
      # @spec MOBILE-API-002
      token.revoke!
      get "/api/v1/probe", headers: auth_headers
      revoked_message = response.parsed_body.dig("error", "message")

      get "/api/v1/probe"
      missing_message = response.parsed_body.dig("error", "message")

      get "/api/v1/probe", headers: { "Authorization" => "Bearer paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
      unknown_message = response.parsed_body.dig("error", "message")

      expect(revoked_message).to eq(missing_message)
      expect(unknown_message).to eq(missing_message)
      expect(missing_message).not_to match(/revoke|expire|malform|unknown/i)
    end

    it "does not accept the token via a query parameter" do
      # @spec MOBILE-API-005
      get "/api/v1/probe", params: { token: plaintext, access_token: plaintext }

      expect(response).to have_http_status(:unauthorized)
    end

    it "responds with JSON, never a Devise HTML redirect" do
      # @spec MOBILE-API-002
      get "/api/v1/probe"

      expect(response.media_type).to eq("application/json")
      expect(response.body).not_to include("<html")
    end
  end

  describe "SSE requests" do
    it "authenticates via the bearer header before any stream bytes are written" do
      # @spec MOBILE-API-005
      get "/api/v1/probe/stream", headers: auth_headers.merge("Accept" => "text/event-stream")

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/event-stream")
      expect(response.body).to start_with("event:")
      expect(response.body).to include(user.id.to_s)
    end

    it "rejects an invalid bearer with the JSON envelope instead of starting the stream" do
      # @spec MOBILE-API-005
      # @spec MOBILE-API-002
      token.revoke!

      get "/api/v1/probe/stream", headers: auth_headers.merge("Accept" => "text/event-stream")

      expect(response).to have_http_status(:unauthorized)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
      expect(response.body).not_to start_with("event:")
    end

    it "does not accept a query-parameter token for streams" do
      # @spec MOBILE-API-005
      get "/api/v1/probe/stream", params: { token: plaintext }, headers: { "Accept" => "text/event-stream" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "tenant isolation across accounts" do
    it "never resolves account A's tenant context from account B's token data" do
      # @spec MOBILE-API-005
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_plaintext = PersonalAccessToken.generate_plaintext
      other_token = create(:personal_access_token, user: other_user, account: other_account, name: "iPad",
        plaintext: other_plaintext)

      get "/api/v1/probe", headers: { "Authorization" => "Bearer #{other_plaintext}" }

      expect(response.parsed_body["account_id"]).to eq(other_account.id)
      expect(response.parsed_body["account_id"]).not_to eq(account.id)
      expect(other_token.reload.account_id).to eq(other_account.id)
    end

    it "scopes policy-visible tokens per account through the Pundit scope" do
      # @spec MOBILE-API-005
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_plaintext = PersonalAccessToken.generate_plaintext
      create(:personal_access_token, user: other_user, account: other_account, name: "iPad",
        plaintext: other_plaintext)

      visible_to_a = PersonalAccessTokenPolicy::Scope.new(user, PersonalAccessToken).resolve.count
      visible_to_b = PersonalAccessTokenPolicy::Scope.new(other_user, PersonalAccessToken).resolve.count

      expect(visible_to_a).to eq(1)
      expect(visible_to_b).to eq(1)
    end
  end
end
