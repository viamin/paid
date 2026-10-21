# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mobile chat diagram comments API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:diagram) { create(:chat_diagram, chat_session:) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let(:headers) do
    create(:personal_access_token, user:, account:, name: "iPhone", plaintext:)
    { "Authorization" => "Bearer #{plaintext}" }
  end
  let(:path) { "/api/v1/chat/sessions/#{chat_session.id}/diagrams/#{diagram.id}/comments" }

  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-012
  it "records actor and selected text through the bearer-authenticated endpoint" do
    expect {
      post path, params: { body: "Can this retry?", element_id: "app" }, headers: headers, as: :json
    }.to change(ChatDiagramComment, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include(
      "actor_id" => user.id,
      "question_key" => diagram.question_key,
      "element_context" => "Application: The Paid application."
    )
  end

  # @spec QUESTION-EXPLORATION-006 QUESTION-EXPLORATION-012
  it "returns stale_element when the selected diagram element no longer exists" do
    post path, params: { body: "Can this retry?", element_id: "missing" }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("stale_element")
    expect(ChatDiagramComment).not_to exist
  end

  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-012
  it "returns validation_failed without creating an oversized comment" do
    expect {
      post path, params: { body: "a" * 12_001 }, headers: headers, as: :json
    }.not_to change(ChatDiagramComment, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
  end

  # @spec QUESTION-EXPLORATION-012
  it "requires the chat scope and does not expose another account's session" do
    inbox_only_plaintext = PersonalAccessToken.generate_plaintext
    create(:personal_access_token, user:, account:, name: "Inbox-only", scopes: %w[inbox], plaintext: inbox_only_plaintext)

    post path, params: { body: "Can this retry?" }, headers: { "Authorization" => "Bearer #{inbox_only_plaintext}" }, as: :json
    expect(response).to have_http_status(:forbidden)

    foreign_account = create(:account)
    foreign_user = create(:user, account: foreign_account)
    foreign_session = create(:chat_session, account: foreign_account, created_by: foreign_user)
    foreign_diagram = create(:chat_diagram, chat_session: foreign_session)

    post "/api/v1/chat/sessions/#{foreign_session.id}/diagrams/#{foreign_diagram.id}/comments",
      params: { body: "Can this retry?" }, headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end
end
