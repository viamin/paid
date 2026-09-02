# frozen_string_literal: true

require "net/http"
require "qdrant"

# Thin wrapper around Qdrant::Client with error handling and health checks.
#
# Translates low-level network exceptions into QdrantClient::ConnectionError so
# callers can rescue a single hierarchy.
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
    defined?(Faraday::ConnectionFailed) ? Faraday::ConnectionFailed : nil,
    defined?(Faraday::TimeoutError) ? Faraday::TimeoutError : nil,
    Errno::ECONNREFUSED,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
    Timeout::Error
  ].freeze
    .compact

  # Default timeout in seconds for Qdrant HTTP requests.
  DEFAULT_TIMEOUT = 5

  # Default timeout in seconds for opening a connection to Qdrant.
  DEFAULT_OPEN_TIMEOUT = 3

  # @param url [String] Qdrant REST API URL
  # @param api_key [String, nil] Optional API key for authentication
  # @param timeout [Integer] Read timeout in seconds (default: 5)
  # @param open_timeout [Integer] Connection open timeout in seconds (default: 3)
  def initialize(url:, api_key: nil, timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT,
                 logger: self.class.default_logger)
    @client = Qdrant::Client.new(url: url, api_key: api_key, logger: logger)
    @timeout = timeout
    @open_timeout = open_timeout
    configure_connection!
  end

  # The upstream Qdrant gem defaults to `Logger.new($stdout)` and logs each
  # request/response directly from the transport layer. Route logging through
  # Rails.logger (or a silent logger when Rails isn't initialized) so log level
  # settings actually take effect.
  def self.default_logger
    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger
    else
      Logger.new(IO::NULL)
    end
  end

  # Returns the Qdrant collections resource with error handling.
  #
  # @return [Qdrant::Collections] wrapped with error handling
  # @raise [ConnectionError] if Qdrant is unreachable
  def collections
    ErrorProxy.new(client.collections)
  end

  # Returns the Qdrant points resource with error handling.
  #
  # @return [Qdrant::Points] wrapped with error handling
  # @raise [ConnectionError] if Qdrant is unreachable
  def points
    ErrorProxy.new(client.points)
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

  # Wraps a Qdrant resource object to catch and translate connection errors.
  class ErrorProxy
    def initialize(resource)
      @resource = resource
    end

    def method_missing(method, ...)
      @resource.send(method, ...)
    rescue *CONNECTION_ERRORS => e
      raise QdrantClient::ConnectionError,
        "Qdrant connection error during ##{method}: #{e.message}",
        e.backtrace
    end

    def respond_to_missing?(method, _include_private = false)
      @resource.respond_to?(method)
    end
  end

  attr_reader :client

  def configure_connection!
    timeout = @timeout
    open_timeout = @open_timeout
    logger = client.instance_variable_get(:@logger)
    api_key = client.instance_variable_get(:@api_key)

    client.instance_variable_set(
      :@connection,
      Connection.new(
        url: client.instance_variable_get(:@url),
        api_key: api_key,
        raise_error: false,
        logger: logger,
        timeout: timeout,
        open_timeout: open_timeout
      )
    )
  end

  class Connection < Qdrant::Client::Connection
    def initialize(url:, api_key:, raise_error:, logger:, timeout:, open_timeout:)
      super(url: url, api_key: api_key, raise_error: raise_error, logger: logger)
      @timeout = timeout
      @open_timeout = open_timeout
    end

    private

    def execute(verb, path, &block)
      request = build_timed_request(verb, path, &block)
      perform_request(request)
    end

    def build_timed_request(verb, path, &block)
      Qdrant::Client::RequestBuilder.new(verb, @uri, path, @api_key, @logger)
        .tap(&block)
        .build
    end

    def perform_request(request)
      request_uri = request.instance_variable_get(:@uri)
      request_data = request.instance_variable_get(:@data)

      @logger.info("Performing Request: #{request_verb_name(request)} #{request_uri}")

      response = Net::HTTP.new(request_uri.host, request_uri.port).tap do |http|
        http.use_ssl = true if request_uri.scheme == "https"
        http.read_timeout = @timeout
        http.open_timeout = @open_timeout
      end.request(request_data)

      response.value if @raise_error

      @logger.info("Response status: #{response.code}")
      Qdrant::Client::ResponseBuilder.new(response).build
    rescue => e
      @logger.error("Request failed: #{e.class}: #{e.message}")
      raise
    end

    def request_verb_name(request)
      request.send(:verb_name)
    end
  end
end
