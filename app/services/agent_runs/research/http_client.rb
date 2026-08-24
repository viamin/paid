# frozen_string_literal: true

require "ipaddr"
require "net/http"
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
      NON_PUBLIC_CIDRS = %w[
        0.0.0.0/8
        10.0.0.0/8
        100.64.0.0/10
        127.0.0.0/8
        169.254.0.0/16
        172.16.0.0/12
        192.0.0.0/24
        192.0.2.0/24
        192.168.0.0/16
        198.18.0.0/15
        198.51.100.0/24
        203.0.113.0/24
        224.0.0.0/4
        240.0.0.0/4
        255.255.255.255/32
        ::/128
        ::1/128
        64:ff9b:1::/48
        100::/64
        2001::/23
        2001:2::/48
        2001:db8::/32
        2002::/16
        fc00::/7
        fe80::/10
        ff00::/8
      ].map { |cidr| IPAddr.new(cidr) }.freeze

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
          resolved_address = resolve_safe_address(current_uri)

          response = connection_for(current_uri, address: resolved_address)
            .run_request(method.downcase.to_sym, request_path(current_uri), nil, request_headers)
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

          raise UpstreamError, "Brokered research upstream returned status #{status}" unless success_status?(status)

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

      def connection_for(uri, address:)
        Faraday.new(url: origin_for(uri)) do |builder|
          builder.options.open_timeout = OPEN_TIMEOUT
          builder.options.timeout = READ_TIMEOUT
          builder.adapter :net_http do |http|
            http.ipaddr = address
          end
        end
      end

      def request_headers
        { "User-Agent" => "PaidResearchBroker/1.0" }
      end

      def request_path(uri)
        uri.request_uri.presence || "/"
      end

      def origin_for(uri)
        "#{uri.scheme}://#{uri.host}:#{uri.port}"
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
      # The actual socket is then pinned to the resolved IP via
      # +Net::HTTP#ipaddr+, which closes the DNS-rebinding window while
      # preserving the original hostname for TLS SNI and certificate
      # verification.
      # @spec EGRESS-POLICY-008
      # @spec EGRESS-POLICY-009
      def resolve_safe_address(uri)
        addresses = resolve_addresses(uri.host)
        if addresses.empty?
          raise RequestInvalidError, "URL host #{uri.host.inspect} could not be resolved"
        end

        if addresses.any? { |ip| !public_address?(ip) }
          raise RequestInvalidError, "URL host #{uri.host.inspect} resolves to a non-public address"
        end

        addresses.first
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
        return false if non_public_address?(ip)
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

      def non_public_address?(ip)
        NON_PUBLIC_CIDRS.any? { |range| range.include?(ip) }
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

      def success_status?(status)
        status.between?(200, 299)
      end

      def allowed_content_type?(content_type)
        ALLOWED_CONTENT_TYPES.include?(content_type)
      end
    end
  end
end
