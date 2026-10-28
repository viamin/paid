# frozen_string_literal: true

module OpenrouterZdr
  class Client
    class Error < StandardError; end
    class ResponseError < Error; end
    class ParseError < Error; end

    Snapshot = Data.define(:endpoints, :models)

    ZDR_API_URL = "https://openrouter.ai/api/v1/endpoints/zdr"
    MODELS_API_URL = "https://openrouter.ai/api/v1/models"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    def call
      Snapshot.new(endpoints: get_data(ZDR_API_URL), models: get_data(MODELS_API_URL))
    end

    private

    def get_data(url)
      response = connection.get(url)
      raise ResponseError, "OpenRouter request failed with status #{response.status}" unless response.success?

      parsed_data(response.body)
    rescue JSON::ParserError => e
      raise ParseError, "OpenRouter response was invalid JSON: #{e.message}"
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise Error, "OpenRouter request failed: #{e.message}"
    end

    def parsed_data(body)
      data = JSON.parse(body.to_s)["data"]
      return data if data.is_a?(Array)

      raise ParseError, "OpenRouter response did not include a data array"
    end

    def connection
      @connection ||= Faraday.new do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.timeout = READ_TIMEOUT
      end
    end
  end
end
