# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::GithubWebhooks" do
  let(:project) { create(:project, webhook_secret: "test-secret-123") }
  let(:agent_run) { create(:agent_run, :completed, project: project) }
  let(:webhook_url) { "/api/github_webhooks" }

  def sign_payload(payload, secret)
    body = payload.to_json
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
    [ body, signature ]
  end

  describe "POST /api/github_webhooks" do
    context "with pull_request_review event" do
      let(:payload) do
        {
          action: "submitted",
          review: {
            state: "approved",
            user: { login: "reviewer" },
            body: "Looks good!"
          },
          pull_request: {
            number: agent_run.pull_request_number
          },
          repository: {
            id: project.github_id,
            full_name: project.full_name
          }
        }
      end

      it "records review feedback for matching agent run" do
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "pull_request_review",
              "X-Hub-Signature-256" => signature
            }
        }.to change { QualityMetric.human.count }.by(1)

        expect(response).to have_http_status(:ok)
      end

      it "returns ok when no matching agent run found" do
        payload[:pull_request][:number] = 9999
        body, signature = sign_payload(payload, project.webhook_secret)

        post webhook_url,
          params: body,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request_review",
            "X-Hub-Signature-256" => signature
          }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with signature verification" do
      let(:payload) do
        {
          repository: { id: project.github_id, full_name: project.full_name },
          pull_request: { number: 1 }
        }
      end

      it "rejects requests without signature" do
        post webhook_url,
          params: payload.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request_review"
          }

        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects requests with invalid signature" do
        body, _signature = sign_payload(payload, project.webhook_secret)

        post webhook_url,
          params: body,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request_review",
            "X-Hub-Signature-256" => "sha256=invalid"
          }

        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects requests for projects without webhook secret" do
        project.update!(webhook_secret: nil)
        body, signature = sign_payload(payload, "any-secret")

        post webhook_url,
          params: body,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "pull_request_review",
            "X-Hub-Signature-256" => signature
          }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with non-completed agent run" do
      it "does not record feedback for running agent runs" do
        running_run = create(:agent_run, :running, project: project, pull_request_number: 42)
        payload = {
          action: "submitted",
          review: { state: "approved", user: { login: "reviewer" }, body: "LGTM" },
          pull_request: { number: running_run.pull_request_number },
          repository: { id: project.github_id, full_name: project.full_name }
        }
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "pull_request_review",
              "X-Hub-Signature-256" => signature
            }
        }.not_to change { QualityMetric.human.count }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with unsupported event" do
      it "returns ok for push events" do
        payload = { repository: { id: project.github_id, full_name: project.full_name } }
        body, signature = sign_payload(payload, project.webhook_secret)

        post webhook_url,
          params: body,
          headers: {
            "Content-Type" => "application/json",
            "X-GitHub-Event" => "push",
            "X-Hub-Signature-256" => signature
          }

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
