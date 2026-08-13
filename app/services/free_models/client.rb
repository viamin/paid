# frozen_string_literal: true

module FreeModels
  class Client
    class Error < StandardError; end
    class ResponseError < Error; end
    class ParseError < Error; end

    API_URL = "https://openrouter.ai/api/v1/models"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-001
    def call
      response = connection.get
      raise ResponseError, "OpenRouter models request failed with status #{response.status}" unless response.success?

      payload = JSON.parse(response.body.to_s)
      data = payload["data"]
      return data if data.is_a?(Array)

      raise ParseError, "OpenRouter models response did not include a data array"
    rescue JSON::ParserError => e
      raise ParseError, "OpenRouter models response was invalid JSON: #{e.message}"
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise Error, "OpenRouter models request failed: #{e.message}"
    end

    private

    def connection
      @connection ||= Faraday.new(url: API_URL) do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.timeout = READ_TIMEOUT
      end
    end
  end
end
