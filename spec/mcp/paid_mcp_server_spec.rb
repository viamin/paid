# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaidMcpServer do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:server) { described_class.new(session: chat_session, user: user) }
  let(:project) { create(:project, account: account) }

  describe "#handle_request" do
    it "handles initialize" do
      result = server.handle_request(method: "initialize", id: 1)

      expect(result[:result][:protocolVersion]).to eq("2024-11-05")
      expect(result[:result][:serverInfo][:name]).to eq("paid-mcp-server")
      expect(result[:result][:capabilities][:tools]).to eq({ listChanged: true })
    end

    it "accepts initialized notifications" do
      result = server.handle_request(method: "notifications/initialized")

      expect(result).to be_nil
    end

    it "handles tools/list" do
      create(:project_membership, :member, user: user, project: project)

      result = server.handle_request(method: "tools/list", id: 2)

      expect(result[:result][:tools]).to be_an(Array)
      expect(result[:result][:tools].first).to have_key(:name)
      expect(result[:result][:tools].first).to have_key(:inputSchema)
      expect(result[:result][:tools].map { |tool| tool[:name] }).not_to include("trigger_agent_run")
    end

    it "keeps container tools discoverable in tools/list before the workspace is ready" do
      manifest = [ { project_id: project.id, path: "/workspace/repo-one" } ]
      pending_session = create(
        :chat_session,
        account: account,
        created_by: user,
        container_capability: "pending",
        clone_manifest: manifest
      )
      pending_server = described_class.new(session: pending_session, user: user)

      pending_result = pending_server.handle_request(method: "tools/list", id: 21)

      expect(pending_result[:result][:tools].map { |tool| tool[:name] }).to include("git_status", "git_diff")
    end

    it "returns a structured unavailable result when a container tool is called before ready" do
      manifest = [ { project_id: project.id, path: "/workspace/repo-one" } ]
      session = create(:chat_session, account: account, created_by: user, container_capability: "pending", clone_manifest: manifest)
      pending_server = described_class.new(session: session, user: user)

      result = pending_server.handle_request(
        method: "tools/call",
        params: { "name" => "git_status", "arguments" => { "repo_path" => "/workspace/repo-one" } },
        id: 22
      )

      content = JSON.parse(result[:result][:content].first[:text])
      expect(content).to include(
        "status" => "error",
        "error" => "container_unavailable",
        "container_capability" => "pending",
        "retryable" => true
      )
    end

    it "handles tools/call" do
      project

      result = server.handle_request(
        method: "tools/call",
        params: { "name" => "list_projects", "arguments" => {} },
        id: 3
      )

      expect(result[:result][:content]).to be_an(Array)
      content = JSON.parse(result[:result][:content].first[:text])
      expect(content.size).to eq(1)
    end

    it "returns error for unknown method" do
      result = server.handle_request(method: "unknown", id: 4)

      expect(result[:error][:code]).to eq(-32601)
    end

    it "returns error for unknown tool" do
      result = server.handle_request(
        method: "tools/call",
        params: { "name" => "nonexistent", "arguments" => {} },
        id: 5
      )

      expect(result[:error][:code]).to eq(-32602)
    end

    it "returns invalid params when tool arguments are not an object" do
      result = server.handle_request(
        method: "tools/call",
        params: { "name" => "list_projects", "arguments" => [] },
        id: 6
      )

      expect(result[:error]).to eq(code: -32602, message: "Tool arguments must be a JSON object")
    end

    it "rejects direct calls to write tools hidden from tools/list" do
      create(:project_membership, :member, user: user, project: project)

      result = server.handle_request(
        method: "tools/call",
        params: { "name" => "trigger_agent_run", "arguments" => {} },
        id: 7
      )

      expect(result[:error]).to eq(code: -32602, message: "Unknown tool: trigger_agent_run")
    end

    it "does not expose operator tools to non-operators" do
      result = server.handle_request(method: "tools/list", id: 8)

      tool_names = result[:result][:tools].map { |tool| tool[:name] }
      expect(tool_names.grep(/\Aoperator_/)).to eq([])
      expect(tool_names).not_to include("operator_console_inventory")
    end
  end

  describe "#tool_definitions" do
    it "returns read-only tool definitions" do
      create(:project_membership, :member, user: user, project: project)

      definitions = server.tool_definitions

      expect(definitions).to be_an(Array)
      names = definitions.map { |d| d[:name] }
      expect(names).to include(
        "list_projects", "get_project", "get_project_issues",
        "get_project_pull_requests", "get_agent_run", "list_agent_runs",
        "get_issue_details", "get_pull_request_details", "search_code",
        "list_account_memberships", "get_user_settings", "list_provider_api_keys"
      )
      expect(names).not_to include("trigger_agent_run", "cancel_agent_run")
    end

    it "includes inputSchema for each tool" do
      definitions = server.tool_definitions

      definitions.each do |definition|
        expect(definition).to have_key(:inputSchema)
        expect(definition[:inputSchema][:type]).to eq("object")
      end
    end
  end

  describe ".tools_list_changed_notification" do
    it "builds an MCP notification payload" do
      notification = described_class.tools_list_changed_notification(
        session: chat_session,
        from: "pending",
        to: "ready"
      )

      expect(notification).to eq(
        jsonrpc: "2.0",
        method: "notifications/tools/list_changed",
        params: {
          sessionId: chat_session.external_id,
          containerCapability: "ready",
          previousContainerCapability: "pending"
        }
      )
    end
  end

  describe "#call_tool" do
    it "routes tool calls through the registry" do
      allow(Tools::Registry).to receive(:dispatch_mcp).and_return([])

      server.call_tool(name: "list_projects", arguments: {})

      expect(Tools::Registry).to have_received(:dispatch_mcp).with(
        name: "list_projects",
        arguments: {},
        user: user,
        session: chat_session
      )
    end
  end

  describe "operator tools" do
    let(:operator_account) { create(:account) }
    let(:operator) { create(:user, :owner, account: operator_account) }
    let(:target_account) { create(:account) }
    let(:operator_session) { create(:chat_session, account: operator_account, created_by: operator) }
    let(:operator_server) { described_class.new(session: operator_session, user: operator) }

    around do |example|
      original_emails = ENV["PAID_OPERATOR_EMAILS"]
      ENV["PAID_OPERATOR_EMAILS"] = operator.email
      example.run
    ensure
      ENV["PAID_OPERATOR_EMAILS"] = original_emails
    end

    it "lists only read-only operator tools for operators" do
      result = operator_server.handle_request(method: "tools/list", id: 9)
      tool_names = result[:result][:tools].map { |tool| tool[:name] }

      expect(tool_names).to include("operator_console_inventory", "operator_list_accounts")
      expect(tool_names).not_to include("operator_suspend_account")
    end

    it "rejects direct operator write calls on the raw MCP surface" do
      call_result = operator_server.handle_request(
        method: "tools/call",
        params: {
          "name" => "operator_suspend_account",
          "arguments" => { "account_id" => target_account.id, "confirmed" => true }
        },
        id: 10
      )

      expect(call_result[:error]).to eq(code: -32602, message: "Unknown tool: operator_suspend_account")
      expect(target_account.reload).not_to be_suspended
    end
  end

  describe "rate limiting" do
    it "raises RateLimitExceeded when limit is hit" do
      allow(Rails.cache).to receive(:increment).and_return(PaidMcpServer::RATE_LIMIT_MAX + 1)

      result = server.handle_request(
        method: "tools/call",
        params: { "name" => "list_projects", "arguments" => {} },
        id: 1
      )

      expect(result[:error][:code]).to eq(-32029)
    end

    it "initializes counter when increment returns nil" do
      allow(Rails.cache).to receive(:increment).and_return(nil)
      allow(Rails.cache).to receive(:write)

      create(:project, account: account)

      result = server.handle_request(
        method: "tools/call",
        params: { "name" => "list_projects", "arguments" => {} },
        id: 1
      )

      expect(Rails.cache).to have_received(:write).with(
        "mcp:rate_limit:#{chat_session.id}", 1, expires_in: 1.minute
      )
      expect(result[:result]).to be_present
    end

    it "does not rate limit non-tool-call methods" do
      allow(Rails.cache).to receive(:increment).and_return(PaidMcpServer::RATE_LIMIT_MAX + 1)

      result = server.handle_request(method: "tools/list", id: 1)

      expect(result[:result]).to be_present
    end
  end
end
