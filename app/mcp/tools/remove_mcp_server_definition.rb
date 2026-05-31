# frozen_string_literal: true

module Tools
  class RemoveMcpServerDefinition < BaseTool
    authorize :destroy?, ->(args) { mcp_server_definition_for(args.fetch(:mcp_server_definition_id)) }, policy_class: McpServerDefinitionPolicy

    def self.tool_name = "remove_mcp_server_definition"
    def self.write_operation? = true

    def self.description
      "Remove an MCP server definition from the current account."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          mcp_server_definition_id: { type: "integer" },
          confirmed: { type: "boolean" }
        },
        required: %w[mcp_server_definition_id confirmed]
      }
    end

    def self.available_to?(user:)
      record = user&.account&.mcp_server_definitions&.build
      policy_allows?(user:, record:, query: :destroy?, policy_class: McpServerDefinitionPolicy)
    end

    def perform(mcp_server_definition_id:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to remove an MCP server definition" unless confirmed

      definition = mcp_server_definition_for(mcp_server_definition_id)
      result = { id: definition.id, name: definition.name }
      definition.destroy!
      result
    end

    private

    def mcp_server_definition_for(definition_id)
      policy_scope(McpServerDefinition).find(definition_id)
    end
  end
end
