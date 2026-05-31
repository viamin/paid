# frozen_string_literal: true

module Tools
  module McpServerDefinitionAttributes
    PERMITTED_ATTRIBUTES = %i[
      name
      transport
      install_type
      command
      args_json
      url
      image
      env_json
      enabled
      metadata_json
    ].freeze

    private

    def normalize_mcp_server_definition_attributes(attributes)
      attributes.symbolize_keys.slice(*PERMITTED_ATTRIBUTES).tap do |attrs|
        normalize_json_attribute!(attrs, :args_json, :args)
        normalize_json_attribute!(attrs, :env_json, :env)
        normalize_json_attribute!(attrs, :metadata_json, :metadata)
      end
    end

    def normalize_json_attribute!(attrs, json_key, record_key)
      return unless attrs.key?(json_key)
      return if attrs[json_key].is_a?(String)

      value = attrs.delete(json_key)
      attrs[record_key] =
        if value.nil?
          default_value_for(record_key)
        else
          value
        end
    end

    def default_value_for(record_key)
      case record_key
      when :args then []
      when :env, :metadata then {}
      end
    end
  end
end
