# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mobile API tenant enforcement" do # @spec RAILS-CONTROL-PLANE-006
  let(:user) { create(:user, account:) }
  let(:plaintext) { "paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
  let(:token) do
    PersonalAccessToken.create!(
      user:,
      account:,
      name: "Mobile",
      scopes: %w[inbox chat],
      token_digest: PersonalAccessToken.digest(plaintext)
    )
  end
  let(:headers) { token; { "Authorization" => "Bearer #{plaintext}" } }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: [ "What should happen?" ]) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "mobile") }

  describe "suspended account" do
    let(:account) { create(:account, status: :suspended, suspended_at: Time.current) }

    it "allows read requests" do
      issue
      get "/api/v1/inbox/count", headers: headers

      expect(response).to have_http_status(:ok)
    end

    it "blocks the chat write endpoint" do
      entry_id = "clarifying_questions:#{issue.id}"

      post "/api/v1/inbox/entries/#{entry_id}/chat", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
    end
  end

  describe "deactivated account" do
    let(:account) { create(:account, status: :deactivated, deactivated_at: Time.current) }

    it "blocks read requests" do
      get "/api/v1/inbox/count", headers: headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
    end

    it "blocks the chat write endpoint" do
      entry_id = "clarifying_questions:#{issue&.id}"

      post "/api/v1/inbox/entries/#{entry_id}/chat", headers: headers

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
