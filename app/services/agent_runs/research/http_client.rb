# frozen_string_literal: true

require "ipaddr"
require "resolv"

module AgentRuns
  module Research
    # @spec EGRESS-POLICY-008
    # @spec EGRESS-POLICY-009
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
      DNS_TIMEOUT = 3

      # Cloud metadata service endpoints reachable from brokered-research
      # connections. Listed alongside the loopback/link-local/private IPv6
      # checks in +#public_address?+ so the SSRF guard never lets a
      # host resolve through to one of these.
      METADATA_IPS = %w[169.254.169.254 fd00:ec2::254].freeze

      def self.fetch(url:, method:, dns_resolver: nil)
        new(dns_resolver: dns_resolver).fetch(url: url, method: method)
      end

      def initialize(dns_resolver: nil)
        @dns_resolver = dns_resolver
      end

      def fetch(url:, method:)
        raise RequestInvalidError, "Brokered research only supports GET/HEAD" unless ALLOWED_METHODS.include?(method)

        current_uri = normalize_uri(url)
        redirect_chain = []

        loop do
          pinned_uri = pin_to_safe_address(current_uri)

          response = connection.run_request(method.downcase.to_sym, pinned_uri.to_s, nil, pinned_request_headers(current_uri.host))
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

      # +Host+ must echo the original hostname so virtual-hosted upstreams
      # route correctly after +#pin_to_safe_address+ rewrites the URL host
      # to an IP.
      def pinned_request_headers(host)
        request_headers.merge("Host" => host)
      end

      def normalize_uri(value)
        uri = URI.parse(value)
        validate_uri_shape!(uri)
        uri
      end

      def validate_uri_shape!(uri)
        raise RequestInvalidError, "URL must use http or https" unless uri.scheme.in?(%w[http https])
        raise RequestInvalidError, "URL must include a host" if uri.host.blank?
        raise RequestInvalidError, "URL credentials are not allowed" if uri.userinfo.present?
        raise RequestInvalidError, "URL fragments are not allowed" if uri.fragment.present?

        host_error = AgentRuns::EgressPolicy::HostPattern.invalid_reason(uri.host.to_s)
        raise RequestInvalidError, "URL host #{host_error}" if host_error
      end

      # Resolves +host+ to A/AAAA records and fails closed if any result
      # targets a private, loopback, link-local, or metadata address, or
      # if resolution returns no addresses (NXDOMAIN, timeout). Direct
      # IP-literal hosts are validated against the same ranges. Hostname
      # syntax alone is not enough — an attacker can register
      # +attacker.example+ to resolve to +127.0.0.1+,
      # +169.254.169.254+, or any RFC1918/ULA range, so we resolve and
      # inspect every hop before the underlying HTTP client connects.
      # Replacing the URL host with the resolved IP (and echoing the
      # original hostname on the +Host+ header) also closes the
      # DNS-rebinding window between validation and connection.
      # @spec EGRESS-POLICY-008
      # @spec EGRESS-POLICY-009
      def pin_to_safe_address(uri)
        addresses = resolve_addresses(uri.host)
        if addresses.empty?
          raise RequestInvalidError, "URL host #{uri.host.inspect} could not be resolved"
        end

        if addresses.any? { |ip| !public_address?(ip) }
          raise RequestInvalidError, "URL host #{uri.host.inspect} resolves to a non-public address"
        end

        pinned = uri.dup
        pinned.host = addresses.first
        pinned
      end

      def resolve_addresses(host)
        return [ host ] if ip_literal?(host)

        resources = []
        resources.concat(dns_resolver.getresources(host, Resolv::DNS::Resource::IN::A))
        resources.concat(dns_resolver.getresources(host, Resolv::DNS::Resource::IN::AAAA))
        resources.map { |resource| resource.address.to_s }.uniq
      rescue Resolv::ResolvError, Resolv::ResolvTimeout
        []
      end

      def ip_literal?(host)
        IPAddr.new(host)
        true
      rescue IPAddr::Error
        false
      end

      def public_address?(address)
        ip = IPAddr.new(address)
        return false if ip.loopback? || ip.link_local? || ip.private?
        return false if metadata_address?(ip)

        true
      rescue IPAddr::Error
        false
      end

      def metadata_address?(ip)
        METADATA_IPS.any? { |address| IPAddr.new(address) == ip }
      rescue IPAddr::Error
        false
      end

      def dns_resolver
        @dns_resolver ||= begin
          resolver = Resolv::DNS.new
          resolver.timeouts = DNS_TIMEOUT
          resolver
        end
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
