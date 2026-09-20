# frozen_string_literal: true

module AgentRuns
  module AppleVerification
    # Declarative, credential-free network contract for an Apple verification
    # guest (RDR-068). Built from the run's resolved {AgentRuns::EgressPolicy::Snapshot}
    # so the guest boundary always matches the same platform/tenant/operator/
    # project/run authority every other run's egress is resolved from — this
    # segment does not create an Apple-specific allowlist.
    #
    # The contract carries only what a guest needs to route traffic: the Paid
    # DNS marker, the proxy endpoint (host/port, no userinfo or credentials),
    # and the destinations the resolved snapshot allows. The actual Tart/
    # Softnet transport that installs this contract on a guest belongs to
    # #3933; this object is deliberately transport-agnostic.
    # @spec APPLE-NETWORK-001
    # @spec APPLE-NETWORK-002
    class GuestContract
      DNS = "paid"
      SCHEMES = %w[http https].freeze

      attr_reader :dns, :proxy, :destinations, :egress_profile

      def initialize(proxy:, destinations:, egress_profile:)
        @dns = DNS
        @proxy = proxy.freeze
        @destinations = destinations.freeze
        @egress_profile = egress_profile
        freeze
      end

      def self.from_snapshot(snapshot)
        new(
          proxy: proxy_destination(snapshot),
          destinations: allowed_destinations(snapshot),
          egress_profile: snapshot.egress_profile
        )
      end

      def self.proxy_destination(snapshot)
        entry = snapshot.required_destinations.find { |destination| destination["reason"] == "secrets_proxy" }
        raise NetworkPolicyError, "resolved snapshot is missing the required secrets-proxy destination" unless entry

        { host: entry.fetch("host"), port: entry.fetch("port") }
      end
      private_class_method :proxy_destination

      def self.allowed_destinations(snapshot)
        snapshot.destinations.map { |destination| { host: destination["host"], port: destination["port"] } }
      end
      private_class_method :allowed_destinations
    end
  end
end
