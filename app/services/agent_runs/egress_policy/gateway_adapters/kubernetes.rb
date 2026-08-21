# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    module GatewayAdapters
      # Kubernetes egress gateway adapter contract (RDR-055).
      #
      # Production translation pair:
      #
      # - CNI + NetworkPolicy restricts the agent pod's egress to the
      #   service-local gateway Pod.
      # - The gateway service runs in the same namespace as the agent pod
      #   so the platform's default-deny NetworkPolicy keeps the policy
      #   intact across cluster nodes.
      #
      # This stub does not perform the CNI/NetworkPolicy calls; it only
      # declares the contract and reports +capable?+ so a runner that
      # delegates to Kubernetes can be wired in without re-deriving the
      # gateway shape. A real implementation lands with the Kubernetes
      # runner (RDR-048 follow-ups) and replaces the URL placeholder.
      # @spec EGRESS-POLICY-007
      class Kubernetes < Base
        GATEWAY_HOST = "egress-gateway"
        GATEWAY_PORT = 3128

        def capable?(snapshot: nil, backend: nil)
          backend.respond_to?(:kubernetes?) ? backend.kubernetes? : false
        end

        def ensure!(agent_run:, snapshot:, backend:)
          raise Gateway::UnavailableError, "kubernetes adapter requires a Kubernetes backend" unless capable?(backend: backend)
        end

        def gateway_url(snapshot:, backend:)
          "#{GATEWAY_HOST}.#{namespace_for(backend)}.svc.cluster.local:#{GATEWAY_PORT}"
        end

        def allowlist_for(snapshot:)
          Array(snapshot&.destinations).map do |destination|
            { host: destination["host"], port: destination["port"] }.compact
          end
        end

        private

        def namespace_for(backend)
          backend.respond_to?(:namespace) ? backend.namespace : "default"
        end
      end
    end
  end
end
