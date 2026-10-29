# frozen_string_literal: true

module OpenrouterZdr
  class Client
    class Error < StandardError; end
    class ResponseError < Error; end
    class ParseError < Error; end

    API_URL = "https://openrouter.ai/api/v1/endpoints/zdr"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    # @spec FREE-MODEL-SYNC-012
    def call
      response = connection.get
      raise ResponseError, "OpenRouter ZDR endpoints request failed with status #{response.status}" unless response.success?

      validate_endpoints!(JSON.parse(response.body.to_s).fetch("data"))
    rescue KeyError, TypeError, JSON::ParserError => e
      raise ParseError, "OpenRouter ZDR endpoints response was invalid: #{e.message}"
    rescue Faraday::Error => e
      raise Error, "OpenRouter ZDR endpoints request failed: #{e.message}"
    end

    private

    def validate_endpoints!(endpoints)
      raise ParseError, "OpenRouter ZDR endpoints response did not include a data array" unless endpoints.is_a?(Array)
      raise ParseError, "OpenRouter ZDR endpoint did not include a model_id" unless endpoints.all? { |endpoint| endpoint.is_a?(Hash) && endpoint["model_id"].present? }

      endpoints
    end

    def connection
      @connection ||= Faraday.new(url: API_URL) do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.timeout = READ_TIMEOUT
      end
    end
  end
end
