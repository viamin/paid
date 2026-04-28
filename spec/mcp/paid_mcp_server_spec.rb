# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaidMcpServer do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:server) { described_class.new(session: chat_session, user: user) }

  describe "#handle_request" do
    it "handles initialize" do
      result = server.handle_request(method: "initialize", id: 1)

      expect(result[:result][:protocolVersion]).to eq("2024-11-05")
      expect(result[:result][:serverInfo][:name]).to eq("paid-mcp-server")
      expect(result[:result][:capabilities][:tools]).to eq({ listChanged: false })
    end

    it "handles tools/list" do
      result = server.handle_request(method: "tools/list", id: 2)

      expect(result[:result][:tools]).to be_an(Array)
      expect(result[:result][:tools].first).to have_key(:name)
      expect(result[:result][:tools].first).to have_key(:inputSchema)
    end

    it "handles tools/call" do
      create(:project, account: account)

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
  end

  describe "#tool_definitions" do
    it "returns all registered tool definitions" do
      definitions = server.tool_definitions

      expect(definitions).to be_an(Array)
      names = definitions.map { |d| d[:name] }
      expect(names).to include(
        "list_projects", "get_project", "get_project_issues",
        "get_project_pull_requests", "trigger_agent_run", "get_agent_run",
        "list_agent_runs", "cancel_agent_run", "get_issue_details",
        "get_pull_request_details", "search_code"
      )
    end

    it "includes inputSchema for each tool" do
      definitions = server.tool_definitions

      definitions.each do |definition|
        expect(definition).to have_key(:inputSchema)
        expect(definition[:inputSchema][:type]).to eq("object")
      end
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

    it "does not rate limit non-tool-call methods" do
      allow(Rails.cache).to receive(:increment).and_return(PaidMcpServer::RATE_LIMIT_MAX + 1)

      result = server.handle_request(method: "tools/list", id: 1)

      expect(result[:result]).to be_present
    end
  end
end
