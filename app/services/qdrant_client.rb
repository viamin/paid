# frozen_string_literal: true

require "qdrant"

# Thin wrapper around Qdrant::Client with error handling and health checks.
#
# Translates low-level network exceptions (Faraday::ConnectionFailed, etc.)
# into QdrantClient::ConnectionError so callers can rescue a single hierarchy.
# Error wrapping applies to all method calls on returned resource objects
# (e.g. client.collections.list), not just the accessor itself.
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

  # Default timeout in seconds for Qdrant HTTP requests.
  DEFAULT_TIMEOUT = 5

  # Default timeout in seconds for opening a connection to Qdrant.
  DEFAULT_OPEN_TIMEOUT = 3

  # @param url [String] Qdrant REST API URL
  # @param api_key [String, nil] Optional API key for authentication
  # @param timeout [Integer] Read timeout in seconds (default: 5)
  # @param open_timeout [Integer] Connection open timeout in seconds (default: 3)
  def initialize(url:, api_key: nil, timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT)
    @client = Qdrant::Client.new(url: url, api_key: api_key)
    @client.connection.options.timeout = timeout
    @client.connection.options.open_timeout = open_timeout
  end

  # Returns a proxy around {Qdrant::Client#collections} that wraps connection
  # errors on any subsequent method call (e.g. .list, .create).
  #
  # @return [ErrorWrappingProxy] proxy around Qdrant::Collections
  # @raise [ConnectionError] if Qdrant is unreachable
  def collections
    ErrorWrappingProxy.new(client.collections)
  end

  # Returns a proxy around {Qdrant::Client#points} that wraps connection
  # errors on any subsequent method call (e.g. .upsert, .search).
  #
  # @return [ErrorWrappingProxy] proxy around Qdrant::Points
  # @raise [ConnectionError] if Qdrant is unreachable
  def points
    ErrorWrappingProxy.new(client.points)
  end

  # Checks whether the Qdrant service is reachable and responsive.
  #
  # @return [Boolean] true if Qdrant responds to a collection list request
  def healthy?
    collections.list
    true
  rescue ConnectionError, *CONNECTION_ERRORS
    false
  end

  private

  attr_reader :client

  # Delegates all method calls to the wrapped object while catching
  # Faraday connection errors and re-raising as QdrantClient::ConnectionError.
  class ErrorWrappingProxy < SimpleDelegator
    def method_missing(method, ...)
      super
    rescue *CONNECTION_ERRORS => e
      raise QdrantClient::ConnectionError,
        "Qdrant connection error during ##{method}: #{e.message}",
        e.backtrace
    end
  end
end
