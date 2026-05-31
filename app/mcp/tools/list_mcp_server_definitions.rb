# frozen_string_literal: true

module Tools
  class ListMcpServerDefinitions < BaseTool
    authorize :index?, ->(_args) { McpServerDefinition }, policy_class: McpServerDefinitionPolicy

    def self.tool_name = "list_mcp_server_definitions"

    def self.description
      "List MCP server definitions for the current account."
    end

    def self.available_to?(user:)
      policy_allows?(user:, record: McpServerDefinition, query: :index?, policy_class: McpServerDefinitionPolicy)
    end

    def perform
      policy_scope(McpServerDefinition).order(created_at: :desc).map do |definition|
        serialize_summary(definition)
      end
    end

    private

    def serialize_summary(definition)
      definition.attributes.slice(
        "id",
        "name",
        "install_type",
        "transport",
        "enabled"
      )
    end
  end
end
