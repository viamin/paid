# frozen_string_literal: true

module Tools
  class CreateMcpServerDefinition < BaseTool
    include McpServerDefinitionAttributes

    authorize :create?, ->(_args) { account.mcp_server_definitions.build }, policy_class: McpServerDefinitionPolicy

    def self.tool_name = "create_mcp_server_definition"
    def self.write_operation? = true

    def self.description
      "Create an MCP server definition for the current account."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          attributes: { type: "object" },
          confirmed: { type: "boolean" }
        },
        required: %w[attributes confirmed]
      }
    end

    def self.available_to?(user:)
      record = user&.account&.mcp_server_definitions&.build
      policy_allows?(user:, record:, query: :create?, policy_class: McpServerDefinitionPolicy)
    end

    def perform(attributes:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to create an MCP server definition" unless confirmed
      raise ArgumentError, "attributes must be an object" unless attributes.is_a?(Hash)

      definition = account.mcp_server_definitions.create!(normalize_mcp_server_definition_attributes(attributes))
      McpServerDefinitionSerialization.serialize_mcp_server_definition(definition)
    end
  end
end
