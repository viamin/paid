# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Main CI webhook reconciliation" do
  include ActiveJob::TestHelper

  let(:project) { create(:project, webhook_secret: "main-ci-secret", review_settings: { "main_ci_recovery" => {
    "enabled" => true, "required_workflows" => [ ".github/workflows/ci.yml" ], "executor_revision" => "e" * 40
  } }) }

  # @spec MAIN-CI-001
  it "wakes reconciliation only for authenticated completed events" do
    %w[workflow_run check_suite check_run].each do |event|
      body = { action: "completed", repository: { id: project.github_id, full_name: project.full_name } }.to_json
      signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', project.webhook_secret, body)}"
      expect do
        post "/api/github_webhooks", params: body, headers: { "Content-Type" => "application/json",
          "X-GitHub-Event" => event, "X-Hub-Signature-256" => signature }
      end.to have_enqueued_job(MainCiReconciliationJob).with(project.id)
      expect(response).to have_http_status(:ok)
    end
  end

  # @spec MAIN-CI-001
  it "rejects an unauthenticated event before enqueueing" do
    body = { action: "completed", repository: { id: project.github_id, full_name: project.full_name } }.to_json
    expect do
      post "/api/github_webhooks", params: body, headers: { "Content-Type" => "application/json",
        "X-GitHub-Event" => "workflow_run", "X-Hub-Signature-256" => "sha256=invalid" }
    end.not_to have_enqueued_job(MainCiReconciliationJob)
    expect(response).to have_http_status(:unauthorized)
  end
end
