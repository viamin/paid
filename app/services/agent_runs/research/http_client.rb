# frozen_string_literal: true

module AgentRuns
  module Research
    class HttpClient
      Result = Data.define(:uri, :status, :content_type, :body, :redirect_chain)

      ALLOWED_METHODS = %w[GET HEAD].freeze
      ALLOWED_CONTENT_TYPES = [
        "text/plain",
        "text/html",
        "application/json",
        "text/markdown",
        "application/markdown"
      ].freeze
      MAX_REDIRECTS = 3
      MAX_RESPONSE_BYTES = 150_000
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10

      def self.fetch(...)
        new.fetch(...)
      end

      def fetch(url:, method:)
        raise RequestInvalidError, "Brokered research only supports GET/HEAD" unless ALLOWED_METHODS.include?(method)

        current_uri = normalize_uri(url)
        redirect_chain = []

        loop do
          response = connection.run_request(method.downcase.to_sym, current_uri.to_s, nil, request_headers)
          status = response.status.to_i

          if redirect_status?(status)
            location = response.headers["location"].to_s
            raise RequestInvalidError, "Redirect response was missing a location header" if location.blank?
            raise RequestInvalidError, "Redirect chain exceeded #{MAX_REDIRECTS} hops" if redirect_chain.length >= MAX_REDIRECTS

            next_uri = normalize_uri(current_uri.merge(location).to_s)
            redirect_chain << { "status" => status, "location" => next_uri.to_s }
            current_uri = next_uri
            next
          end

          body = method == "HEAD" ? "" : response.body.to_s
          raise RequestInvalidError, "Response exceeded #{MAX_RESPONSE_BYTES} bytes" if body.bytesize > MAX_RESPONSE_BYTES

          content_type = response.headers["content-type"].to_s.split(";").first.to_s.downcase
          raise RequestInvalidError, "Response content type #{content_type.inspect} is not allowed" unless allowed_content_type?(content_type)

          return Result.new(
            uri: current_uri,
            status: status,
            content_type: content_type,
            body: body,
            redirect_chain: redirect_chain
          )
        end
      rescue URI::InvalidURIError => error
        raise RequestInvalidError, error.message
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => error
        raise UpstreamError, error.message
      rescue Faraday::Error => error
        raise UpstreamError, error.message
      end

      private

      def connection
        @connection ||= Faraday.new do |builder|
          builder.options.open_timeout = OPEN_TIMEOUT
          builder.options.timeout = READ_TIMEOUT
        end
      end

      def request_headers
        { "User-Agent" => "PaidResearchBroker/1.0" }
      end

      def normalize_uri(value)
        uri = URI.parse(value)
        validate_uri!(uri)
        uri
      end

      def validate_uri!(uri)
        raise RequestInvalidError, "URL must use http or https" unless uri.scheme.in?(%w[http https])
        raise RequestInvalidError, "URL must include a host" if uri.host.blank?
        raise RequestInvalidError, "URL credentials are not allowed" if uri.userinfo.present?
        raise RequestInvalidError, "URL fragments are not allowed" if uri.fragment.present?

        host_error = AgentRuns::EgressPolicy::HostPattern.invalid_reason(uri.host.to_s)
        raise RequestInvalidError, "URL host #{host_error}" if host_error
      end

      def redirect_status?(status)
        [ 301, 302, 303, 307, 308 ].include?(status)
      end

      def allowed_content_type?(content_type)
        ALLOWED_CONTENT_TYPES.include?(content_type)
      end
    end
  end
end
