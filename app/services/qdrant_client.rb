# frozen_string_literal: true

require "delegate"
require "net/http"
require "qdrant"

# Thin wrapper around Qdrant::Client with error handling and health checks.
#
# Translates low-level network exceptions into QdrantClient::ConnectionError so
# callers can rescue a single hierarchy.
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
    install_timed_connection!(
      url: url,
      api_key: api_key,
      timeout: timeout,
      open_timeout: open_timeout,
      logger: logger
    )
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

  def install_timed_connection!(url:, api_key:, timeout:, open_timeout:, logger:)
    client.instance_variable_set(
      :@connection,
      TimedConnection.new(
        url: url,
        api_key: api_key,
        raise_error: false,
        logger: logger,
        timeout: timeout,
        open_timeout: open_timeout
      )
    )
  end

  class TimedConnection < Qdrant::Client::Connection
    def initialize(url:, api_key:, raise_error:, logger:, timeout:, open_timeout:)
      super(url: url, api_key: api_key, raise_error: raise_error, logger: logger)
      @timeout = timeout
      @open_timeout = open_timeout
    end

    private

    def execute(verb, path, &block)
      response = TimedRequestBuilder
        .new(verb, @uri, path, @api_key, @logger, timeout: @timeout, open_timeout: @open_timeout)
        .tap(&block)
        .build
        .perform(@raise_error)

      Qdrant::Client::ResponseBuilder.new(response).build
    end
  end

  # Delegates all method calls to the wrapped object while catching
  # Qdrant transport errors and re-raising as QdrantClient::ConnectionError.
  class ErrorWrappingProxy < SimpleDelegator
    def method_missing(method, ...)
      super
    rescue *CONNECTION_ERRORS => e
      raise QdrantClient::ConnectionError,
        "Qdrant connection error during ##{method}: #{e.message}",
        e.backtrace
    end
  end

  class TimedRequestBuilder < Qdrant::Client::RequestBuilder
    def initialize(verb, base_url, path, api_key, logger, timeout:, open_timeout:)
      super(verb, base_url, path, api_key, logger)
      @timeout = timeout
      @open_timeout = open_timeout
    end

    def build
      TimedRequest.new(
        build_uri,
        @verb,
        @request.body,
        @api_key,
        @logger,
        timeout: @timeout,
        open_timeout: @open_timeout
      )
    end
  end

  class TimedRequest < Qdrant::Client::Request
    def initialize(uri, verb, body, api_key, logger, timeout:, open_timeout:)
      super(uri, verb, body, api_key, logger)
      @timeout = timeout
      @open_timeout = open_timeout
    end

    def perform(raise_error)
      @logger.info("Performing Request: #{verb_name} #{@uri}")

      response = Net::HTTP.new(@uri.host, @uri.port).tap do |http|
        http.use_ssl = true if @uri.scheme == "https"
        http.read_timeout = @timeout
        http.open_timeout = @open_timeout
      end.request(@data)

      response.value if raise_error

      @logger.info("Response status: #{response.code}")
      response
    rescue => e
      @logger.error("#{verb_name} #{@uri} failed: #{e.class}: #{e.message}")
      raise
    end
  end
end
