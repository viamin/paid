# frozen_string_literal: true

require "uri"

module AppleVerification
  # Translates Paid's existing egress snapshot into the fail-closed network
  # contract an Apple-worker provider must install before booting a guest.
  # @spec APPLE-NETWORK-001
  # @spec APPLE-NETWORK-002
  # @spec APPLE-NETWORK-003
  class GuestNetworkPolicy
    ALLOWED_PROTOCOLS = %w[http https].freeze
    BLOCKED_LITERAL = "blocked-literal"

    class UnavailableError < StandardError; end

    class NetworkPolicyError < StandardError
      attr_reader :failure_category

      def initialize(message)
        @failure_category = "network_policy"
        super(message)
      end
    end

    def self.resolve_and_persist!(agent_run:, proxy_url:, dns_server:)
      ensure_enabled!(agent_run.project)
      snapshot = AgentRuns::EgressPolicy::Resolve.resolve_and_persist!(
        agent_run,
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
      )
      new(agent_run:, snapshot:, proxy_url:, dns_server:)
    end

    def self.ensure_enabled!(project)
      return if FeatureFlags.enabled?(:apple_verification_workers, project: project)

      raise UnavailableError, "Apple verification workers are disabled for this project"
    end

    def initialize(agent_run:, snapshot:, proxy_url:, dns_server:)
      self.class.ensure_enabled!(agent_run.project)
      @agent_run = agent_run
      @snapshot = snapshot
      @proxy_url = normalized_proxy_url(proxy_url)
      @dns_server = validated_dns_server(dns_server)
    end

    def contract
      {
        "version" => 1,
        "default_route" => "deny",
        "host_services" => "deny",
        "dns" => { "mode" => "paid_only", "server" => dns_server },
        "proxy" => { "url" => proxy_url, "override" => "blocked" },
        "protocols" => ALLOWED_PROTOCOLS,
        "destinations" => destinations
      }
    end

    def allow_request!(host:, port:, scheme:, dns_server:, proxy_url:)
      reason = denial_reason(host:, port:, scheme:, dns_server:, proxy_url:)
      return true unless reason

      record_denial!(host:, port:, scheme:, reason:)
      raise NetworkPolicyError, "Apple guest network policy denied request: #{reason}"
    end

    private

    attr_reader :agent_run, :snapshot, :proxy_url, :dns_server

    def denial_reason(host:, port:, scheme:, dns_server:, proxy_url:)
      return "unsupported protocol" unless ALLOWED_PROTOCOLS.include?(scheme.to_s)
      return "direct IP or invalid hostname" if AgentRuns::EgressPolicy::HostPattern.invalid_reason(host)
      return "alternate DNS is blocked" unless dns_server.to_s == self.dns_server
      return "proxy override is blocked" unless normalized_proxy_url(proxy_url) == self.proxy_url
      return "destination is not allowed" unless allowed_destination?(host, port, scheme)

      nil
    rescue ArgumentError
      "proxy override is blocked"
    end

    def allowed_destination?(host, port, scheme)
      destinations.any? do |destination|
        AgentRuns::EgressPolicy::HostPattern.matches?(destination["host"], host) &&
          (destination["port"].nil? || destination["port"].to_i == port.to_i) &&
          (destination["scheme"].nil? || destination["scheme"] == scheme.to_s)
      end
    end

    def destinations
      @destinations ||= snapshot.destinations.map { |destination| destination.stringify_keys.slice("host", "port", "scheme", "source") }
    end

    def normalized_proxy_url(value)
      uri = URI.parse(value.to_s)
      raise ArgumentError, "Paid proxy URL must use http or https" unless ALLOWED_PROTOCOLS.include?(uri.scheme)
      raise ArgumentError, "Paid proxy URL must not include credentials" if uri.userinfo.present?
      raise ArgumentError, "Paid proxy URL must include a host" if uri.host.blank?
      raise ArgumentError, "Paid proxy URL must not include a path" unless uri.path.in?([ "", "/" ])
      raise ArgumentError, "Paid proxy URL must not include a query or fragment" if uri.query.present? || uri.fragment.present?

      uri.to_s.delete_suffix("/")
    rescue URI::InvalidURIError
      raise ArgumentError, "Paid proxy URL is invalid"
    end

    def validated_dns_server(value)
      return value if AgentRuns::EgressPolicy::HostPattern.invalid_reason(value).nil?

      raise ArgumentError, "Paid DNS server must be a public hostname"
    end

    def record_denial!(host:, port:, scheme:, reason:)
      EgressSecurityEvent.create!(
        account: agent_run.project.account,
        project: agent_run.project,
        agent_run: agent_run,
        event_kind: "denied_egress",
        severity: "warn",
        source_layer: "apple_guest",
        destination_host: safe_destination(host),
        destination_port: safe_port(port),
        scheme: safe_scheme(scheme),
        matched_rule: reason,
        occurred_at: Time.current
      )
      ExecutionAuditEvents::Lifecycle.record(
        event_name: "apple_verification.network_policy_denied",
        actor_id: nil,
        agent_run: agent_run,
        networking_policy: { mode: "proxy_only", decision: "denied", reason: reason },
        metadata: { destination: safe_destination(host), port: safe_port(port), scheme: safe_scheme(scheme) }
      )
    end

    def safe_destination(host)
      return host.to_s.downcase if AgentRuns::EgressPolicy::HostPattern.invalid_reason(host).nil?

      BLOCKED_LITERAL
    end

    def safe_port(port)
      integer = Integer(port, exception: false)
      integer if integer&.between?(1, 65_535)
    end

    def safe_scheme(scheme)
      scheme.to_s if ALLOWED_PROTOCOLS.include?(scheme.to_s)
    end
  end
end
