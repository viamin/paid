# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 unified error envelope" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }

  # @spec MOBILE-API-015
  it "maps Pundit::NotAuthorizedError to 403 forbidden, not the StandardError fallback" do
    inbox_only_plaintext = PersonalAccessToken.generate_plaintext
    create(:personal_access_token, user:, account:, name: "Inbox-only", scopes: %w[inbox], plaintext: inbox_only_plaintext)

    get "/api/v1/chat/sessions", headers: { "Authorization" => "Bearer #{inbox_only_plaintext}" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to match("error" => { "code" => "forbidden", "message" => be_a(String), "details" => {} })
  end

  # @spec MOBILE-API-015
  it "maps ActiveRecord::RecordNotFound to 404 not_found, not the StandardError fallback" do
    create(:personal_access_token, user:, account:, name: "iPhone", scopes: %w[chat], plaintext:)

    get "/api/v1/chat/sessions/#{SecureRandom.uuid}", headers: { "Authorization" => "Bearer #{plaintext}" }

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to match("error" => { "code" => "not_found", "message" => be_a(String), "details" => {} })
  end
end
