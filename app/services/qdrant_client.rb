# frozen_string_literal: true

require "qdrant"

# Thin wrapper around Qdrant::Client with error handling and health checks.
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

  delegate :collections, :points, to: :client

  # @param url [String] Qdrant REST API URL
  # @param api_key [String, nil] Optional API key for authentication
  def initialize(url:, api_key: nil)
    @client = Qdrant::Client.new(url: url, api_key: api_key)
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
