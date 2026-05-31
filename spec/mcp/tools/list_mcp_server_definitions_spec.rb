# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListMcpServerDefinitions do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  describe Tools::ListMcpServerDefinitions do
    it "lists account MCP server definitions with summary fields only" do
      definition = create(
        :mcp_server_definition,
        account:,
        command: "npx @paid/docs-mcp",
        env: { "API_KEY" => "secret" },
        metadata: { "category" => "docs" }
      )

      result = described_class.new(user:, session:).call
      serialized_definition = result.find { |row| (row["id"] || row[:id]) == definition.id }

      expect(result.map { |row| row["id"] || row[:id] }).to include(definition.id)
      expect(serialized_definition).to include(
        "id" => definition.id,
        "name" => definition.name,
        "install_type" => definition.install_type,
        "transport" => definition.transport,
        "enabled" => definition.enabled
      )
      expect(serialized_definition).not_to include("command", "url", "image", "args", "env", "metadata")
    end
  end

  describe Tools::CreateMcpServerDefinition do
    it "creates an MCP server definition" do
      result = described_class.new(user:, session:).call(
        attributes: {
          name: "Docs Server",
          transport: "stdio",
          install_type: "npx",
          command: "npx @paid/docs-mcp"
        },
        confirmed: true
      )

      expect(result["name"]).to eq("Docs Server")
      expect(account.mcp_server_definitions.find(result["id"]).command).to eq("npx @paid/docs-mcp")
      expect(result).not_to include("account_id", "log_data")
    end

    it "accepts structured MCP payloads for args, env, and metadata" do
      result = described_class.new(user:, session:).call(
        attributes: {
          name: "Docs Server",
          transport: "stdio",
          install_type: "npx",
          command: "npx @paid/docs-mcp",
          args_json: [ "--workspace", "/repo" ],
          env_json: { "API_KEY" => "test" },
          metadata_json: { "category" => "docs" }
        },
        confirmed: true
      )

      definition = account.mcp_server_definitions.find(result["id"])
      expect(definition.args).to eq([ "--workspace", "/repo" ])
      expect(definition.env).to eq({ "API_KEY" => "test" })
      expect(definition.metadata).to eq({ "category" => "docs" })
    end
  end

  describe Tools::UpdateMcpServerDefinition do
    it "updates an MCP server definition" do
      definition = create(:mcp_server_definition, account:)

      result = described_class.new(user:, session:).call(
        mcp_server_definition_id: definition.id,
        attributes: { name: "Updated Server" },
        confirmed: true
      )

      expect(result["name"]).to eq("Updated Server")
      expect(definition.reload.name).to eq("Updated Server")
      expect(result).not_to include("account_id", "log_data")
    end

    it "accepts structured MCP payloads for args, env, and metadata" do
      definition = create(:mcp_server_definition, account:)

      described_class.new(user:, session:).call(
        mcp_server_definition_id: definition.id,
        attributes: {
          args_json: [ "--workspace", "/repo" ],
          env_json: { "API_KEY" => "updated" },
          metadata_json: { "category" => "docs" }
        },
        confirmed: true
      )

      expect(definition.reload.args).to eq([ "--workspace", "/repo" ])
      expect(definition.env).to eq({ "API_KEY" => "updated" })
      expect(definition.metadata).to eq({ "category" => "docs" })
    end
  end

  describe Tools::RemoveMcpServerDefinition do
    it "removes an MCP server definition" do
      definition = create(:mcp_server_definition, account:)

      result = described_class.new(user:, session:).call(
        mcp_server_definition_id: definition.id,
        confirmed: true
      )

      expect(result[:id]).to eq(definition.id)
      expect(account.mcp_server_definitions.where(id: definition.id)).to be_empty
    end
  end
end
