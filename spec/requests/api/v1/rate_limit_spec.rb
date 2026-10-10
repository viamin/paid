# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 per-token rate limiting" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let(:auth_headers) { { "Authorization" => "Bearer #{plaintext}" } }

  before do
    create(:personal_access_token, user: user, name: "iPhone", plaintext: plaintext)
    Api::V1::TokenRateLimit::FALLBACK_CACHE.clear
    stub_const("Api::V1::TokenRateLimit::MAX_REQUESTS", 3)
  end

  it "allows requests within the budget" do
    # @spec MOBILE-API-004
    3.times do
      get "/api/v1/probe", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  it "responds 429 with the unified envelope and a Retry-After header once the budget is exceeded" do
    # @spec MOBILE-API-004
    3.times { get "/api/v1/probe", headers: auth_headers }

    get "/api/v1/probe", headers: auth_headers

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to match(
      "error" => {
        "code" => "rate_limited",
        "message" => be_a(String),
        "details" => {}
      }
    )
    retry_after = response.headers["Retry-After"]
    expect(retry_after).to be_present
    expect(retry_after.to_i).to be_positive
  end

  it "keeps rejecting with 429 until the window resets" do
    # @spec MOBILE-API-004
    3.times { get "/api/v1/probe", headers: auth_headers }
    get "/api/v1/probe", headers: auth_headers

    travel Api::V1::TokenRateLimit::PERIOD + 1.second do
      get "/api/v1/probe", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  it "keys the budget by token id, not by IP or user — another token stays online" do
    # @spec MOBILE-API-004
    other_plaintext = PersonalAccessToken.generate_plaintext
    create(:personal_access_token, user: user, name: "iPad", plaintext: other_plaintext)

    4.times { get "/api/v1/probe", headers: auth_headers }
    expect(response).to have_http_status(:too_many_requests)

    get "/api/v1/probe", headers: { "Authorization" => "Bearer #{other_plaintext}" }
    expect(response).to have_http_status(:ok)
  end

  it "runs a separate budget from the per-user chat message rate limit" do
    # @spec MOBILE-API-004
    4.times { get "/api/v1/probe", headers: auth_headers }
    expect(response).to have_http_status(:too_many_requests)

    expect(ChatMessages::RateLimit.exceeded?(user_id: user.id, chat_session_id: 1)).to be(false)
  end

  it "counts an SSE stream once at stream start, not once per event" do
    # @spec MOBILE-API-004
    sse_headers = auth_headers.merge("Accept" => "text/event-stream")

    get "/api/v1/probe/stream", headers: sse_headers
    expect(response).to have_http_status(:ok)
    expect(response.body.scan(/^event:/).count).to be > 1

    # The multi-event stream above counted as one request; two more requests
    # fit the 3-request budget.
    2.times do
      get "/api/v1/probe", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end

    get "/api/v1/probe", headers: auth_headers
    expect(response).to have_http_status(:too_many_requests)
  end

  it "does not rate-limit requests that already failed authentication" do
    # @spec MOBILE-API-004
    10.times { get "/api/v1/probe" }
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/probe", headers: auth_headers
    expect(response).to have_http_status(:ok)
  end
end
