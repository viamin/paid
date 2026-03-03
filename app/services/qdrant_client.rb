# frozen_string_literal: true

require "qdrant"

# Thin wrapper around Qdrant::Client with error handling and health checks.
#
# Translates low-level network exceptions (Faraday::ConnectionFailed, etc.)
# into QdrantClient::ConnectionError so callers can rescue a single hierarchy.
#
# @example
#   client = QdrantClient.new(url: "http://localhost:6333")
#   client.healthy?  # => true
#   client.collections.list
#
class QdrantClient
  # Base error for all Qdrant client errors
  class Error < StandardError; end

  # Raised when Qdrant is unreachable or returns a connection error
  class ConnectionError < Error; end

  # Connection-level exceptions that indicate Qdrant is unreachable.
  CONNECTION_ERRORS = [
    Faraday::ConnectionFailed,
    Faraday::TimeoutError
  ].freeze

  # @param url [String] Qdrant REST API URL
  # @param api_key [String, nil] Optional API key for authentication
  def initialize(url:, api_key: nil)
    @client = Qdrant::Client.new(url: url, api_key: api_key)
  end

  # Delegates to {Qdrant::Client#collections}, wrapping connection errors.
  #
  # @raise [ConnectionError] if Qdrant is unreachable
  def collections
    client.collections
  rescue *CONNECTION_ERRORS => e
    raise ConnectionError, e.message
  end

  # Delegates to {Qdrant::Client#points}, wrapping connection errors.
  #
  # @raise [ConnectionError] if Qdrant is unreachable
  def points
    client.points
  rescue *CONNECTION_ERRORS => e
    raise ConnectionError, e.message
  end

  # Checks whether the Qdrant service is reachable and responsive.
  #
  # @return [Boolean] true if Qdrant responds to a collection list request
  def healthy?
    client.collections.list
    true
  rescue StandardError
    false
  end

  private

  attr_reader :client
end
