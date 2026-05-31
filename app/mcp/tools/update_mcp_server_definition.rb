# frozen_string_literal: true

module Tools
  class UpdateMcpServerDefinition < BaseTool
    include McpServerDefinitionAttributes

    authorize :update?, ->(args) { mcp_server_definition_for(args.fetch(:mcp_server_definition_id)) }, policy_class: McpServerDefinitionPolicy

    def self.tool_name = "update_mcp_server_definition"
    def self.write_operation? = true

    def self.description
      "Update an MCP server definition for the current account."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          mcp_server_definition_id: { type: "integer" },
          attributes: { type: "object" },
          confirmed: { type: "boolean" }
        },
        required: %w[mcp_server_definition_id attributes confirmed]
      }
    end

    def self.available_to?(user:)
      record = user&.account&.mcp_server_definitions&.build
      policy_allows?(user:, record:, query: :update?, policy_class: McpServerDefinitionPolicy)
    end

    def perform(mcp_server_definition_id:, attributes:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to update an MCP server definition" unless confirmed
      raise ArgumentError, "attributes must be an object" unless attributes.is_a?(Hash)

      definition = mcp_server_definition_for(mcp_server_definition_id)
      definition.update!(normalize_mcp_server_definition_attributes(attributes))
      McpServerDefinitionSerialization.serialize_mcp_server_definition(definition)
    end

    private

    def mcp_server_definition_for(definition_id)
      policy_scope(McpServerDefinition).find(definition_id)
    end
  end
end
