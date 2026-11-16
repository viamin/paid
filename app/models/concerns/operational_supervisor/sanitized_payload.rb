# frozen_string_literal: true

module OperationalSupervisor
  module SanitizedPayload
    FORBIDDEN_KEYS = %w[
      body comment content credentials diff email error exception file log message output
      password path prompt raw raw_error raw_output repository_response secret summary text token
    ].freeze

    def sanitized_payload?(value)
      return false unless value.is_a?(Hash) || value.is_a?(Array)

      safe_value?(value)
    end

    private

    def safe_value?(value)
      case value
      when Hash
        value.all? { |key, item| safe_key?(key) && safe_value?(item) }
      when Array
        value.all? { |item| safe_value?(item) }
      when String
        value.bytesize <= 256
      when Integer, Float, TrueClass, FalseClass, NilClass
        true
      else
        false
      end
    end

    def safe_key?(key)
      key.is_a?(String) && !FORBIDDEN_KEYS.include?(key.downcase)
    end
  end
end
