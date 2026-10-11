# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mobile chat sessions API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let(:headers) do
    create(:personal_access_token, user:, account:, name: "iPhone", plaintext:)
    { "Authorization" => "Bearer #{plaintext}" }
  end
  let!(:chat_session) { create(:chat_session, account:, created_by: user, title: "Native chat") }

  # @spec MOBILE-API-011 CHAT-API-001
  it "lists and creates inline chat sessions through the bearer-authenticated namespace" do
    get "/api/v1/chat/sessions", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("sessions").map { |session| session.fetch("id") }).to include(chat_session.id)

    post "/api/v1/chat/sessions", params: { title: "New native chat" }, headers: headers
    expect(response).to have_http_status(:created)
    created = response.parsed_body
    expect(created).to include("title" => "New native chat", "container_capability" => "none")
  end

  # @spec MOBILE-API-011 CHAT-API-001
  it "updates and transitions a chat session through the bearer-authenticated namespace" do
    patch "/api/v1/chat/sessions/#{chat_session.id}", params: { title: "Renamed" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("title")).to eq("Renamed")

    patch "/api/v1/chat/sessions/#{chat_session.id}/archive", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("archived")

    patch "/api/v1/chat/sessions/#{chat_session.id}/unarchive", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("active")

    delete "/api/v1/chat/sessions/#{chat_session.id}", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  # @spec MOBILE-API-011 MOBILE-API-015
  it "rejects unsupported mobile workspace requests with the unified envelope" do
    post "/api/v1/chat/sessions", params: { container_capability: "pending" }, headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
  end
end
