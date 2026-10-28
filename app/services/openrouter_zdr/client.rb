# frozen_string_literal: true

module OpenrouterZdr
  class Client
    class Error < StandardError; end
    class ResponseError < Error; end
    class ParseError < Error; end

    API_URL = "https://openrouter.ai/api/v1/endpoints/zdr"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    def self.call(...)
      new(...).call
    end

    # @spec FREE-MODEL-SYNC-009
    def call
      response = connection.get
      raise ResponseError, "OpenRouter ZDR endpoints request failed with status #{response.status}" unless response.success?

      data = JSON.parse(response.body.to_s)["data"]
      return data if valid_endpoints?(data)

      raise ParseError, "OpenRouter ZDR endpoints response did not include a data array"
    rescue JSON::ParserError => e
      raise ParseError, "OpenRouter ZDR endpoints response was invalid JSON: #{e.message}"
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise Error, "OpenRouter ZDR endpoints request failed: #{e.message}"
    end

    private

    def valid_endpoints?(data)
      data.is_a?(Array) && data.all? { |endpoint| endpoint.is_a?(Hash) && endpoint["model_id"].present? }
    end

    def connection
      @connection ||= Faraday.new(url: API_URL) do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.timeout = READ_TIMEOUT
      end
    end
  end
end
