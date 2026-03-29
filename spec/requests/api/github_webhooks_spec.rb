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

    context "with pull_request event (merge)" do
      let(:payload) do
        {
          action: "closed",
          pull_request: {
            number: agent_run.pull_request_number,
            merged: true
          },
          repository: {
            id: project.github_id,
            full_name: project.full_name
          }
        }
      end

      it "records pr_merged feedback when PR is merged" do
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "pull_request",
              "X-Hub-Signature-256" => signature
            }
        }.to change { QualityMetric.human.count }.by(1)

        expect(response).to have_http_status(:ok)

        metric = agent_run.quality_metrics.human.last
        expect(metric.scores["pr_merged"]).to eq(1.0)
      end

      it "ignores closed-but-not-merged PRs" do
        payload[:pull_request][:merged] = false
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "pull_request",
              "X-Hub-Signature-256" => signature
            }
        }.not_to change { QualityMetric.human.count }

        expect(response).to have_http_status(:ok)
      end

      it "ignores non-close actions" do
        payload[:action] = "opened"
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "pull_request",
              "X-Hub-Signature-256" => signature
            }
        }.not_to change { QualityMetric.human.count }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with issue_comment event on a PR" do
      let(:payload) do
        {
          action: "created",
          issue: {
            number: agent_run.pull_request_number,
            pull_request: { url: "https://api.github.com/repos/#{project.full_name}/pulls/#{agent_run.pull_request_number}" }
          },
          comment: {
            user: { login: "reviewer" },
            body: "Nice work, but could you fix the typo on line 10?"
          },
          repository: {
            id: project.github_id,
            full_name: project.full_name
          }
        }
      end

      it "records comment feedback for matching agent run" do
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "issue_comment",
              "X-Hub-Signature-256" => signature
            }
        }.to change { QualityMetric.human.count }.by(1)

        expect(response).to have_http_status(:ok)

        metric = agent_run.quality_metrics.human.last
        expect(metric.metadata["webhook_comment_count"]).to eq(1)
        expect(metric.metadata["commenters"]).to include("reviewer")
      end

      it "increments comment count on subsequent comments" do
        body, signature = sign_payload(payload, project.webhook_secret)
        headers = {
          "Content-Type" => "application/json",
          "X-GitHub-Event" => "issue_comment",
          "X-Hub-Signature-256" => signature
        }

        post webhook_url, params: body, headers: headers

        # Second comment from a different user
        payload[:comment][:user][:login] = "another-reviewer"
        body2, signature2 = sign_payload(payload, project.webhook_secret)
        headers2 = headers.merge("X-Hub-Signature-256" => signature2)

        post webhook_url, params: body2, headers: headers2

        metric = agent_run.quality_metrics.human.last
        expect(metric.metadata["webhook_comment_count"]).to eq(2)
        expect(metric.metadata["commenters"]).to contain_exactly("reviewer", "another-reviewer")
      end

      it "ignores edited comments" do
        payload[:action] = "edited"
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "issue_comment",
              "X-Hub-Signature-256" => signature
            }
        }.not_to change { QualityMetric.human.count }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with issue_comment event on an issue" do
      let(:issue_agent_run) do
        create(:agent_run, :completed, project: project, goal: "create_issue", created_issue_number: 55)
      end

      let(:payload) do
        {
          action: "created",
          issue: {
            number: issue_agent_run.created_issue_number
          },
          comment: {
            user: { login: "commenter" },
            body: "Thanks for filing this!"
          },
          repository: {
            id: project.github_id,
            full_name: project.full_name
          }
        }
      end

      it "records comment feedback for agent-created issues" do
        body, signature = sign_payload(payload, project.webhook_secret)

        expect {
          post webhook_url,
            params: body,
            headers: {
              "Content-Type" => "application/json",
              "X-GitHub-Event" => "issue_comment",
              "X-Hub-Signature-256" => signature
            }
        }.to change { QualityMetric.human.count }.by(1)

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
