# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mobile chat investigations API" do
  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-012
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: [ "What should happen?" ]) }
  let(:session) { create(:chat_session, account:, project:, created_by: user, clarifying_question_issue: issue) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let(:headers) do
    create(:personal_access_token, user:, account:, name: "Phone", plaintext:)
    { "Authorization" => "Bearer #{plaintext}" }
  end

  before do
    FeatureFlags.enable!(:question_exploration, project:)
    ClarifyingQuestions::SaveProgress.call(chat_session: session, position: 1, answer: "Investigate", actor: user)
  end

  it "starts, reads, and cancels a reconnectable question investigation" do
    post "/api/v1/chat/sessions/#{session.id}/investigations", params: {
      position: 1, kind: "research", prompt: "Compare the options", estimated_cost_cents: 5
    }, headers: headers

    expect(response).to have_http_status(:created)
    investigation_id = response.parsed_body.fetch("id")

    get "/api/v1/chat/sessions/#{session.id}/investigations/#{investigation_id}", headers: headers
    expect(response.parsed_body).to include("status" => "queued", "question_position" => 1)

    post "/api/v1/chat/sessions/#{session.id}/investigations/#{investigation_id}/cancel", headers: headers
    expect(response.parsed_body).to include("status" => "cancelled")
  end
end
