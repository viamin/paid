# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Design artifact findings API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:finding) { create(:design_artifact_finding, account:, project:, state: "stale_metadata") }
  let(:plaintext) { "paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
  let(:headers) { { "Authorization" => "Bearer #{plaintext}", "Content-Type" => "application/json" } }

  before do
    PersonalAccessToken.create!(
      user:, account:, name: "Inbox", scopes: [ "inbox" ], token_digest: PersonalAccessToken.digest(plaintext)
    )
    create(:runner, user:, runner_key: "codex")
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  it "queues a stale-metadata document-link repair through the API" do
    post "/api/v1/projects/#{project.id}/design_artifact_findings/#{finding.id}/repair_document_links",
      params: { revision: finding.revision }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("agent_run")).to include("status" => "queued")
    expect(finding.reload).to have_attributes(status: "assigned", resolution_actor: user)
  end
end
