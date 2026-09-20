# frozen_string_literal: true

module AgentRuns
  module AppleVerification
    # Validates a single {GuestNetworkRequest} against the run's resolved
    # {GuestContract}. Denies direct IP access, alternate DNS, proxy
    # overrides, and unsupported protocols, and permits only HTTP(S)
    # destinations that match the contract. A denial is recorded as an
    # {EgressSecurityEvent} (+source_layer: "apple_guest"+) and an
    # {ExecutionAuditEvent} before raising {NetworkPolicyError}, so a boundary
    # failure is always auditable and distinguishable from a build/test
    # failure.
    # @spec APPLE-NETWORK-002
    # @spec APPLE-NETWORK-003
    class ValidateGuestRequest
      REDACTED_IP_LITERAL = "[redacted-ip-literal]"

      def self.call(agent_run:, contract:, request:)
        new(agent_run: agent_run, contract: contract, request: request).call
      end

      def initialize(agent_run:, contract:, request:)
        @agent_run = agent_run
        @contract = contract
        @request = request
      end

      def call
        reason = denial_reason
        return true if reason.nil?

        deny!(reason)
      end

      private

      attr_reader :agent_run, :contract, :request

      def denial_reason
        return "unsupported protocol #{request.scheme.inspect}" unless GuestContract::SCHEMES.include?(request.scheme.to_s)
        return "alternate DNS server not permitted" if request.dns_server.present?
        return "proxy override not permitted" if request.proxy_override.present?
        return "direct IP access not permitted" if AgentRuns::EgressPolicy::HostPattern.ip_literal?(request.host.to_s)
        return "destination not in guest contract" unless allowed_destination?

        nil
      end

      def allowed_destination?
        contract.destinations.any? do |destination|
          AgentRuns::EgressPolicy::HostPattern.matches?(destination[:host], request.host) &&
            (destination[:port].nil? || destination[:port] == request.port)
        end
      end

      def deny!(reason)
        record_security_event(reason)
        record_audit_event(reason)
        raise NetworkPolicyError, "apple guest network policy denied: #{reason}"
      end

      def record_security_event(reason)
        EgressSecurityEvent.create!(
          account: agent_run.project.account,
          project: agent_run.project,
          agent_run: agent_run,
          event_kind: "denied_egress",
          severity: "warn",
          source_layer: "apple_guest",
          destination_host: safe_destination_host,
          destination_port: safe_destination_port,
          scheme: safe_scheme,
          matched_rule: reason,
          occurred_at: Time.current
        )
      end

      # The +scheme+ column rejects anything outside http/https, so a denial
      # triggered by an unsupported protocol must not try to persist it.
      def safe_scheme
        request.scheme if GuestContract::SCHEMES.include?(request.scheme.to_s)
      end

      # Raw IP literals are never recorded (RDR-068): a direct-IP denial must
      # not persist the literal itself into the audit trail meant to flag it.
      def safe_destination_host
        return REDACTED_IP_LITERAL if AgentRuns::EgressPolicy::HostPattern.ip_literal?(request.host.to_s)

        request.host
      end

      # +destination_port+ requires 1..65535; an out-of-range or malformed
      # port must not block recording the denial itself.
      def safe_destination_port
        port = request.port
        port if port.is_a?(Integer) && port.between?(1, 65_535)
      end

      def record_audit_event(reason)
        ExecutionAuditEvents::Lifecycle.record(
          event_name: "apple_guest.network_policy.denied",
          actor_type: "system",
          actor_id: "apple_verification",
          agent_run: agent_run,
          project: agent_run.project,
          metadata: {
            destination_host: safe_destination_host,
            destination_port: safe_destination_port,
            scheme: request.scheme,
            decision: "denied",
            reason: reason
          }
        )
      end
    end
  end
end
