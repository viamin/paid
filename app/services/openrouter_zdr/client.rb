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

    # @spec OPENROUTER-ZDR-001
    def call
      response = connection.get
      raise ResponseError, "OpenRouter ZDR request failed with status #{response.status}" unless response.success?

      entries = JSON.parse(response.body.to_s).fetch("data")
      validate_entries(entries)
    rescue JSON::ParserError, KeyError, TypeError => e
      raise ParseError, "OpenRouter ZDR response was malformed: #{e.message}"
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise Error, "OpenRouter ZDR request failed: #{e.message}"
    end

    private

    def connection
      @connection ||= Faraday.new(url: API_URL) do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.timeout = READ_TIMEOUT
      end
    end

    def validate_entries(entries)
      raise ParseError, "OpenRouter ZDR response did not include a data array" unless entries.is_a?(Array)
      raise ParseError, "OpenRouter ZDR response included an invalid endpoint" unless entries.all? { |entry| valid_entry?(entry) }

      entries
    end

    def valid_entry?(entry)
      entry.is_a?(Hash) && entry["model_id"].to_s.present? && entry["name"].to_s.present?
    end
  end
end
