# frozen_string_literal: true

module MarketplaceEntries
  module JsonParser
    module_function

    def parse_object!(value, attribute_name:, record:, default: {})
      parsed = parse_json(value, default:)
      return parsed if parsed.is_a?(Hash)

      record.errors.add(attribute_name, "must be a JSON object")
      nil
    end

    def parse_json(value, default:)
      return default if value.nil?
      return value if value.is_a?(Hash)
      return default if value.respond_to?(:empty?) && value.empty?

      JSON.parse(value)
    rescue JSON::ParserError
      :invalid_json
    end
  end
end
