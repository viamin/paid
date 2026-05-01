# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::GitCredentials" do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:github_token) { project.github_token }
  let(:chat_session) { create(:chat_session, :with_project, account: project.account, project: project) }

  let(:valid_headers) do
    {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    }
  end

  describe "GET /api/proxy/git-credentials" do
    context "with valid authentication" do
      it "authenticates container requests under system access" do
        allow(TenantContext).to receive(:with_system_access).and_call_original

        get "/api/proxy/git-credentials", headers: valid_headers

        expect(TenantContext).to have_received(:with_system_access)
        expect(response).to have_http_status(:ok)
      end

      it "switches back into the authenticated run's tenant context for the action" do
        allow(TenantContext).to receive(:apply!).and_call_original
        allow(github_token).to receive(:touch_last_used!).and_wrap_original do |original, *args|
          expect(TenantContext.bypass_enabled?).to be(false)
          expect(Current.account).to eq(project.account)
          original.call(*args)
        end

        get "/api/proxy/git-credentials", headers: valid_headers

        expect(TenantContext).to have_received(:apply!).with(project.account)
        expect(response).to have_http_status(:ok)
      end

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

    context "with pending agent run" do
      let(:pending_run) { create(:agent_run, project: project, status: "pending") }

      it "returns credentials (active but not yet running)" do
        get "/api/proxy/git-credentials",
          headers: {
            "X-Agent-Run-Id" => pending_run.id.to_s,
            "X-Proxy-Token" => pending_run.proxy_token
          }

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("text/plain")

        lines = response.body.strip.split("\n").map(&:strip)
        expect(lines).to include("protocol=https")
        expect(lines).to include("host=github.com")
        expect(lines).to include("username=x-access-token")
        expect(lines).to include("password=#{github_token.token}")
      end

      it "touches last_used_at on the github token for pending runs" do
        expect do
          get "/api/proxy/git-credentials",
            headers: {
              "X-Agent-Run-Id" => pending_run.id.to_s,
              "X-Proxy-Token" => pending_run.proxy_token
            }
        end.to change { github_token.reload.last_used_at }
      end
    end

    context "with finished agent run" do
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

      it "returns forbidden with a configuration error" do
        get "/api/proxy/git-credentials", headers: valid_headers

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to eq("error" => "Project GitHub token is missing or inactive")
      end
    end

    context "with a projectless chat session" do
      let(:chat_session) { create(:chat_session, account: project.account, project: nil) }

      it "returns forbidden instead of raising" do
        get "/api/proxy/git-credentials",
          headers: {
            "X-Chat-Session-Id" => chat_session.id.to_s,
            "X-Proxy-Token" => chat_session.proxy_token
          }

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to eq("error" => "Project is required for git credentials")
      end
    end
  end
end
