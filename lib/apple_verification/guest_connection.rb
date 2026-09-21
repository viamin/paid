# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module AppleVerification
  # Sends a closed-protocol job to the executor baked into the selected guest
  # image. The endpoint is immutable image provenance; the bearer token comes
  # from deployment configuration and is never persisted with image metadata.
  # @spec APPLE-VERIFY-005
  class GuestConnection
    Response = Data.define(:code, :body)

    ConfigurationError = Class.new(StandardError)
    AuthenticationError = Class.new(StandardError)
    DispatchError = Class.new(StandardError)

    class HttpTransport
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 30

      def post(uri:, headers:, body:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        response = http.start { |client| client.request(Net::HTTP::Post.new(uri, headers).tap { |request| request.body = body }) }
        Response.new(code: response.code.to_i, body: response.body)
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, OpenSSL::SSL::SSLError,
             SocketError, SystemCallError, IOError, EOFError => error
        raise DispatchError, "guest executor request failed: #{error.message}"
      end
    end

    def initialize(token: ENV.fetch("APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN", nil), transport: HttpTransport.new)
      @token = token
      @transport = transport
    end

    def dispatch!(image:, manifest:, network_contract:)
      GuestProtocol.validate!(manifest)
      response = @transport.post(uri: executor_uri(image), headers: headers, body: request_body(image, manifest, network_contract))
      return operations_from(response) if success?(response)

      raise AuthenticationError, "guest executor rejected credentials" if response.code.in?([ 401, 403 ])

      raise DispatchError, "guest executor returned HTTP #{response.code}"
    end

    private

    def executor_uri(image)
      raise ConfigurationError, "guest executor token is not configured" if @token.blank?

      uri = URI.parse(image.provenance.fetch("guest_executor_url"))
      return uri if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank?

      raise ConfigurationError, "guest executor URL must be an HTTPS URL without credentials"
    rescue KeyError, TypeError, URI::InvalidURIError
      raise ConfigurationError, "guest executor URL is not configured"
    end

    def headers
      { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json" }
    end

    def request_body(image, manifest, network_contract)
      { image_digest: image.digest, manifest:, network_contract: network_contract.to_h }.to_json
    end

    def success?(response)
      response.code.between?(200, 299)
    end

    def operations_from(response)
      operations = JSON.parse(response.body).fetch("operations")
      return operations if operations.is_a?(Array)

      raise DispatchError, "guest executor response operations must be an array"
    rescue JSON::ParserError, KeyError, TypeError
      raise DispatchError, "guest executor response must include operations"
    end
  end
end
