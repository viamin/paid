# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::GitCredentials" do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:github_token) { project.github_token }

  let(:valid_headers) do
    {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    }
  end

  describe "GET /api/proxy/git-credentials" do
    context "with valid authentication" do
      it "returns git credential helper format" do
        get "/api/proxy/git-credentials", headers: valid_headers

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("text/plain")

        lines = response.body.strip.split("\n").map(&:strip)
        expect(lines).to include("protocol=https")
        expect(lines).to include("host=github.com")
        expect(lines).to include("username=x-access-token")
        expect(lines).to include("password=#{github_token.token}")
      end

      it "touches last_used_at on the github token" do
        expect { get "/api/proxy/git-credentials", headers: valid_headers }
          .to change { github_token.reload.last_used_at }
      end
    end

    context "without X-Agent-Run-Id header" do
      it "returns unauthorized" do
        get "/api/proxy/git-credentials"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with invalid proxy token" do
      it "returns forbidden" do
        get "/api/proxy/git-credentials",
          headers: {
            "X-Agent-Run-Id" => agent_run.id.to_s,
            "X-Proxy-Token" => "invalid-token"
          }

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "with non-running agent run" do
      let(:completed_run) { create(:agent_run, :completed, project: project) }

      it "returns forbidden" do
        get "/api/proxy/git-credentials",
          headers: {
            "X-Agent-Run-Id" => completed_run.id.to_s,
            "X-Proxy-Token" => completed_run.proxy_token
          }

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "with inactive github token" do
      before do
        github_token.update!(revoked_at: Time.current)
      end

      it "returns service unavailable" do
        get "/api/proxy/git-credentials", headers: valid_headers

        expect(response).to have_http_status(:service_unavailable)
      end
    end
  end
end
