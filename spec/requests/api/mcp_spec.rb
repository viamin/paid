# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::McpController" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:session_token) { chat_session.external_id }
  let(:headers) { { "X-Session-Token" => session_token, "Content-Type" => "application/json" } }

  def apple_verification_headers(agent_run)
    headers.merge(
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    )
  end

  def apple_verification_project_and_run
    project = create(:project, account:, apple_verification_mode: "on_demand")
    agent_run = create(:agent_run, :running, project:, initiating_user: user)
    FeatureFlags.enable!(:apple_verification_workers, project:)
    create(:apple_verification_workflow_revision, project:, lifecycle_gate: "agent_iteration")
    [ project, agent_run ]
  end

  describe "POST /api/mcp/call" do
    context "with valid session token" do
      it "handles initialize request" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 1, method: "initialize", params: {}
        }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["result"]["protocolVersion"]).to eq("2024-11-05")
        expect(body["result"]["serverInfo"]["name"]).to eq("paid-mcp-server")
      end

      it "accepts initialized notifications without a response body" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", method: "notifications/initialized", params: {}
        }.to_json, headers: headers

        expect(response).to have_http_status(:no_content)
        expect(response.body).to be_blank
      end

      it "handles tools/list request" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 2, method: "tools/list", params: {}
        }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["result"]["tools"]).to be_an(Array)
        tool_names = body["result"]["tools"].map { |t| t["name"] }
        expect(tool_names).to include("list_projects", "get_project", "list_agent_runs")
        expect(tool_names.grep(/\Aoperator_/)).to eq([])
        expect(tool_names).not_to include("operator_console_inventory")
      end

      it "handles tools/call for list_projects" do
        project = create(:project, account: account)

        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 3, method: "tools/call",
          params: { name: "list_projects", arguments: {} }
        }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        content = JSON.parse(body["result"]["content"].first["text"])
        expect(content.size).to eq(1)
        expect(content.first["id"]).to eq(project.id)
      end

      it "binds Apple verification MCP calls to the proxy-authenticated agent run" do
        project, agent_run = apple_verification_project_and_run

        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 31, method: "tools/list", params: {}
        }.to_json, headers: apple_verification_headers(agent_run)

        names = JSON.parse(response.body).dig("result", "tools").map { |tool| tool["name"] }
        expect(names).to include(
          "verify_apple_project", "get_apple_verification",
          "capture_apple_screenshot", "stop_apple_verification"
        )

        call_apple_verification(project:, agent_run:)
        expect(apple_verification_result).to include("status" => "queued")
      end

      it "rejects an Apple verification run whose proxy token is invalid" do
        project = create(:project, account:, apple_verification_mode: "on_demand")
        agent_run = create(:agent_run, :running, project:, initiating_user: user)

        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 33, method: "tools/list", params: {}
        }.to_json, headers: headers.merge("X-Agent-Run-Id" => agent_run.id.to_s, "X-Proxy-Token" => "invalid")

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)).to include("error" => "Invalid agent run proxy token")
      end

      it "returns error for unknown method" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 4, method: "unknown/method", params: {}
        }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["error"]["code"]).to eq(-32601)
      end

      it "returns error for unknown tool" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 5, method: "tools/call",
          params: { name: "nonexistent_tool", arguments: {} }
        }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["error"]["code"]).to eq(-32602)
      end
    end

    context "without session token" do
      it "returns 401" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 1, method: "initialize", params: {}
        }.to_json, headers: { "Content-Type" => "application/json" }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with inactive session" do
      let(:chat_session) { create(:chat_session, :closed, account: account, created_by: user) }

      it "returns 401" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 1, method: "initialize", params: {}
        }.to_json, headers: headers

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with cross-account authorization" do
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      it "cannot access projects from another account" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 1, method: "tools/call",
          params: { name: "get_project", arguments: { project_id: other_project.id } }
        }.to_json, headers: headers

        body = JSON.parse(response.body)
        expect(body["error"]).to be_present
      end
    end

    context "with rate limiting" do
      it "enforces rate limit on tool calls" do
        allow(Rails.cache).to receive(:increment).and_return(PaidMcpServer::RATE_LIMIT_MAX + 1)

        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 1, method: "tools/call",
          params: { name: "list_projects", arguments: {} }
        }.to_json, headers: headers

        body = JSON.parse(response.body)
        expect(body["error"]["code"]).to eq(-32029)
        expect(body["error"]["message"]).to include("Rate limit")
      end
    end

    context "when the session user is an operator" do
      let(:user) { create(:user, :owner, account: account, email: "operator@example.com") }
      let(:target_account) { create(:account) }

      around do |example|
        original_emails = ENV["PAID_OPERATOR_EMAILS"]
        ENV["PAID_OPERATOR_EMAILS"] = user.email
        example.run
      ensure
        ENV["PAID_OPERATOR_EMAILS"] = original_emails
      end

      it "surfaces only read-only operator tools over MCP" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 6, method: "tools/list", params: {}
        }.to_json, headers: headers

        tool_names = JSON.parse(response.body).dig("result", "tools").map { |tool| tool["name"] }
        expect(tool_names).to include("operator_console_inventory", "operator_list_accounts")
        expect(tool_names).not_to include("operator_suspend_account")
      end

      it "rejects direct operator write calls over MCP" do
        post "/api/mcp/call", params: {
          jsonrpc: "2.0", id: 7, method: "tools/call",
          params: {
            name: "operator_suspend_account",
            arguments: { account_id: target_account.id, confirmed: true }
          }
        }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("code" => -32602, "message" => "Unknown tool: operator_suspend_account")
        expect(target_account.reload).not_to be_suspended
      end
    end
  end

  def call_apple_verification(project:, agent_run:)
    post "/api/mcp/call", params: {
      jsonrpc: "2.0", id: 32, method: "tools/call",
      params: {
        name: "verify_apple_project",
        arguments: {
          project_id: project.id, agent_run_id: agent_run.id,
          bundle_digest: "sha256:#{'a' * 64}", confirmed: true
        }
      }
    }.to_json, headers: apple_verification_headers(agent_run)
  end

  def apple_verification_result
    JSON.parse(JSON.parse(response.body).dig("result", "content", 0, "text"))
  end

  describe "GET /api/mcp/sse" do
    it "rejects unauthenticated requests" do
      get "/api/mcp/sse"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
