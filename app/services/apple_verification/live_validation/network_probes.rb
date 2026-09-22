# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # Executes the adversarial network-policy probes from issue #3978 AC6
    # through the shipped audited validator, so the recorded evidence is
    # produced by the same boundary production guests cross. Denial reasons
    # and the created EgressSecurityEvent / ExecutionAuditEvent references
    # are captured per probe.
    # @spec APPLE-LIVE-003
    class NetworkProbes
      DENIAL_PREFIX = "apple guest network policy denied: "
      # Documentation ranges (RFC 5737) so no real host is ever probed.
      IP_LITERAL_TARGET = "203.0.113.10"
      ROGUE_DNS_SERVER = "198.51.100.53"
      ROGUE_PROXY = "http://198.51.100.1:8080"

      ADVERSARIAL = {
        "network-direct-ip" => { host_kind: :ip_literal, expected_reason: "direct IP access not permitted" },
        "network-alternate-dns" => { host_kind: :allowed, dns_server: ROGUE_DNS_SERVER,
                                     expected_reason: "alternate DNS server not permitted" },
        "network-proxy-override" => { host_kind: :allowed, proxy_override: ROGUE_PROXY,
                                      expected_reason: "proxy override not permitted" },
        "network-unsupported-protocol" => { host_kind: :allowed, scheme: "ftp",
                                            expected_reason: "unsupported protocol" }
      }.freeze
      CONTROL_ID = "network-compliant-request"

      class << self
        def run(agent_run:, contract:, validator: AgentRuns::AppleVerification::ValidateGuestRequest)
          ADVERSARIAL.map { |id, shape| probe(agent_run:, contract:, validator:, id:, shape:, adversarial: true) }
            .append(probe(agent_run:, contract:, validator:, id: CONTROL_ID, shape: { host_kind: :allowed },
              adversarial: false))
        end

        private

        def probe(agent_run:, contract:, validator:, id:, shape:, adversarial:)
          request = request_for(contract, shape)
          before_security = EgressSecurityEvent.where(agent_run:).maximum(:id)
          before_audit = ExecutionAuditEvent.where(agent_run:).maximum(:id)
          begin
            validator.call(agent_run:, contract:, request:)
            permitted_evidence(id, request, adversarial)
          rescue AgentRuns::AppleVerification::NetworkPolicyError => error
            denial_evidence(agent_run:, id:, adversarial:, reason: error.message.delete_prefix(DENIAL_PREFIX),
              security_since: before_security, audit_since: before_audit)
          end
        end

        def request_for(contract, shape)
          host = shape.fetch(:host_kind) == :ip_literal ? IP_LITERAL_TARGET : allowed_host(contract)
          AgentRuns::AppleVerification::GuestNetworkRequest.new(
            host: host, port: 443, scheme: shape.fetch(:scheme, "https"),
            dns_server: shape[:dns_server], proxy_override: shape[:proxy_override]
          )
        end

        def allowed_host(contract)
          contract.destinations.first&.fetch(:host) || contract.proxy.fetch(:host)
        end

        def permitted_evidence(id, request, adversarial)
          if adversarial
            # The raw host is deliberately not interpolated: a permitted
            # direct-IP probe would otherwise persist the literal into the
            # report, which the validator's own audit trail redacts.
            Evidence.new(scenario_id: id, status: :failed,
              detail: "expected denial but the adversarial request was permitted", references: [], recorded_at: Time.current)
          else
            Evidence.new(scenario_id: id, status: :passed,
              detail: "permitted #{request.host} through the Paid egress gateway as configured", references: [],
              recorded_at: Time.current)
          end
        end

        def denial_evidence(agent_run:, id:, adversarial:, reason:, security_since:, audit_since:)
          references = audit_references(agent_run:, security_since:, audit_since:)
          if !adversarial
            Evidence.new(scenario_id: id, status: :failed, detail: "compliant control request denied: #{reason}",
              references: references, recorded_at: Time.current)
          elsif reason == ADVERSARIAL.fetch(id).fetch(:expected_reason)
            Evidence.new(scenario_id: id, status: :passed, detail: "denied: #{reason}", references: references,
              recorded_at: Time.current)
          else
            Evidence.new(scenario_id: id, status: :failed, detail: "denied with unexpected reason: #{reason}",
              references: references, recorded_at: Time.current)
          end
        end

        def audit_references(agent_run:, security_since:, audit_since:)
          [
            *EgressSecurityEvent.where(agent_run:).where("id > ?", security_since.to_i).pluck(:id)
              .map { |id| { "kind" => "egress_security_event", "id" => id } },
            *ExecutionAuditEvent.where(agent_run:).where("id > ?", audit_since.to_i).pluck(:id)
              .map { |id| { "kind" => "execution_audit_event", "id" => id } }
          ]
        end
      end
    end
  end
end
