# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListMcpServerDefinitions do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  describe Tools::ListMcpServerDefinitions do
    it "lists account MCP server definitions" do
      definition = create(:mcp_server_definition, account:)

      result = described_class.new(user:, session:).call

      expect(result.map { |row| row["id"] || row[:id] }).to include(definition.id)
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
