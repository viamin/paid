# frozen_string_literal: true

require "json"

module AppleVerification
  # Authenticated transport for the versioned macOS host-service boundary.
  # The configured endpoint is the lifecycle API root, not a project endpoint.
  # @spec APPLE-WORKER-008
  class HostClient
    def initialize(endpoint:, connection: nil)
      @connection = connection || Faraday.new(url: endpoint)
    end

    def call(version:, operation:, payload:, token:)
      response = connection.post do |request|
        request.headers["Authorization"] = "Bearer #{token}"
        request.headers["Content-Type"] = "application/json"
        request.body = JSON.generate(version:, operation:, payload:)
      end
      parse_response(response)
    end

    private

    attr_reader :connection

    def parse_response(response)
      raise HostService::AuthenticationError, "macOS host request is not authenticated" if response.status == 401
      raise HostService::UnsupportedRequestError, "macOS host request failed with status #{response.status}" unless response.success?

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise HostService::UnsupportedRequestError, "macOS host returned invalid JSON: #{e.message}"
    end
  end
end
