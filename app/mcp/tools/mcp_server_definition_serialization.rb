# frozen_string_literal: true

module Tools
  module McpServerDefinitionSerialization
    module_function

    def serialize_mcp_server_definition(definition)
      definition.attributes.slice(
        "id", "name", "transport", "install_type", "command", "url", "image", "enabled", "created_at", "updated_at"
      ).merge(
        "args" => definition.args,
        "env_keys" => definition.env.keys.sort,
        "metadata" => definition.metadata
      )
    end
  end
end
