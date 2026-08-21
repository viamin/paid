# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    module GatewayAdapters
      # Managed-machine runner egress adapter contract (RDR-055).
      #
      # The translation pair is the provider firewall / security group
      # controlling the VM, plus a sidecar gateway process or platform
      # egress controls (e.g. AWS VPC endpoint policies). Both control
      # planes only need the snapshot's destination list to produce a
      # fail-closed deny-by-default ruleset.
      #
      # Like the Kubernetes adapter, this stub declares the contract
      # without performing provider-specific API calls; a real
      # implementation lands with the managed-machine runner (RDR-019
      # follow-ups).
      # @spec EGRESS-POLICY-007
      class ManagedMachine < Base
        DEFAULT_GATEWAY_HOST = "127.0.0.1"
        DEFAULT_GATEWAY_PORT = 3128

        def capable?(snapshot: nil, backend: nil)
          backend.respond_to?(:provider) ? backend.provider.present? : false
        end

        def ensure!(agent_run:, snapshot:, backend:)
          raise Gateway::UnavailableError, "managed-machine adapter requires a provider firewall backend" unless capable?(backend: backend)
        end

        def gateway_url(snapshot:, backend:)
          "#{DEFAULT_GATEWAY_HOST}:#{DEFAULT_GATEWAY_PORT}"
        end

        def allowlist_for(snapshot:)
          Array(snapshot&.destinations).map do |destination|
            { host: destination["host"], port: destination["port"] }.compact
          end
        end
      end
    end
  end
end
