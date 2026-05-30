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
      policy_scope(McpServerDefinition).includes(:account).order(created_at: :desc).map do |definition|
        serialize_definition(definition)
      end
    end

    private

    def serialize_definition(definition)
      definition.attributes.slice(
        "id", "name", "transport", "install_type", "command", "url", "image", "enabled", "created_at", "updated_at"
      ).merge(
        "args" => definition.args,
        "env" => definition.env,
        "metadata" => definition.metadata
      )
    end
  end
end
