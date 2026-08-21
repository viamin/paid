# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    module GatewayAdapters
      # Docker egress gateway adapter (RDR-055 step 5).
      #
      # The adapter materializes a per-host egress gateway as a long-lived
      # sidecar container running on the restricted +paid_agent+ Docker
      # network. Each agent run connects to the gateway via the
      # +egress-gateway+ Docker network alias; the gateway inspects every
      # CONNECT/HTTP request, allows it only when the destination host
      # matches the per-run allowlist, and logs denials as
      # {EgressSecurityEvent} rows.
      #
      # The adapter does not own the gateway process itself: it is a
      # platform-translation shim. The gateway runs as a Docker container
      # managed by an operator-deployed service. This adapter surfaces the
      # gateway URL + allowlist for the runner and records denials through
      # {Gateway#record_denial!}. A real implementation would replace the
      # URL resolution with a gateway-sidecar lifecycle call — the public
      # API is what callers depend on.
      # @spec EGRESS-POLICY-007
      class Docker < Base
        # The Docker network alias agent containers reach the gateway at.
        # Matches the default egress-gateway destination used by
        # {RequiredDestinations} so firewall rules and snapshot destinations
        # stay in sync.
        GATEWAY_HOST = AgentRuns::EgressPolicy::RequiredDestinations::EGRESS_GATEWAY_HOST
        GATEWAY_PORT = AgentRuns::EgressPolicy::RequiredDestinations::EGRESS_GATEWAY_PORT

        # Well-known path inside the gateway sidecar where the per-run
        # allowlist is written. The gateway process watches or reads
        # this file to know which hosts the current run may reach.
        ALLOWLIST_CONFIG_PATH = "/etc/egress-gateway/allowlist.json"

        # Path inside the sidecar where denied-request events are
        # appended as newline-delimited JSON. The runner reads this
        # after the run to create {EgressSecurityEvent} audit rows.
        DENIAL_LOG_PATH = "/var/log/egress-gateway/denials.jsonl"

        # Whether the platform adapter can enforce the policy. The Docker
        # adapter declares every restricted RDR-062 mode enforceable when
        # the backend exposes a Docker API; non-Docker backends fall
        # through to the Kubernetes/managed-machine adapters or are
        # rejected by the runner.
        def capable?(snapshot: nil, backend: nil)
          true
        end

        # The default Docker gateway is a platform-managed sidecar; the
        # runner does not own the gateway lifecycle (no create/start calls
        # here). But per RDR-055's fail-closed requirement, provisioning
        # must not proceed as if enforcement exists when the sidecar was
        # never deployed. Look the gateway container up by the same name
        # its network alias uses (+GATEWAY_HOST+) and raise
        # {Gateway::UnavailableError} when it is missing, so restricted
        # runs stop before the agent container starts.
        def ensure!(agent_run:, snapshot:, backend:)
          backend.get_container(GATEWAY_HOST)
          nil
        rescue ::Docker::Error::NotFoundError
          raise Gateway::UnavailableError, "egress gateway container '#{GATEWAY_HOST}' not found on backend #{backend.identifier}"
        rescue ::Docker::Error::DockerError => e
          raise Gateway::UnavailableError, "egress gateway lookup failed on backend #{backend.identifier}: #{e.message}"
        end

        # Installs the per-run allowlist into the gateway sidecar by
        # writing a JSON config to {ALLOWLIST_CONFIG_PATH}. The gateway
        # process reads this file to filter CONNECT/HTTP requests by
        # host against the run's snapshot destinations.
        def install_allowlist!(agent_run:, snapshot:, backend:)
          gateway_container = backend.get_container(GATEWAY_HOST)
          allowlist = allowlist_for(snapshot: snapshot)
          config = JSON.generate(
            agent_run_id: agent_run.id,
            allowlist: allowlist,
            installed_at: Time.current.iso8601
          )
          encoded = Base64.strict_encode64(config)
          backend.exec_in_container(
            gateway_container,
            [ "sh", "-c", "echo '#{encoded}' | base64 -d > #{ALLOWLIST_CONFIG_PATH}" ],
            wait: 5
          )
        rescue ::Docker::Error::DockerError => e
          raise Gateway::UnavailableError,
            "failed to install allowlist on gateway '#{GATEWAY_HOST}': #{e.message}"
        end

        # Reads denial events from the gateway sidecar's denial log.
        # Each line is a JSON object with at least +host+, +port+, and
        # +matched_rule+. Returns an empty array when the log does not
        # exist or the gateway has not recorded any denials.
        def collect_denials(agent_run:, backend:)
          gateway_container = backend.get_container(GATEWAY_HOST)
          stdout, _stderr, exit_code = backend.exec_in_container(
            gateway_container,
            [ "sh", "-c", "cat #{DENIAL_LOG_PATH} 2>/dev/null || true" ],
            wait: 5
          )
          return [] unless exit_code&.zero?

          stdout.join.each_line.filter_map do |line|
            parsed = JSON.parse(line.strip)
            { host: parsed["host"], port: parsed["port"],
              matched_rule: parsed["matched_rule"], scheme: parsed["scheme"] }
          rescue JSON::ParserError
            nil
          end
        rescue ::Docker::Error::DockerError
          []
        end

        def gateway_url(snapshot:, backend:)
          "#{GATEWAY_HOST}:#{GATEWAY_PORT}"
        end

        # The Docker gateway enforces the same host allowlist the snapshot
        # records. Returning the snapshot destinations verbatim keeps the
        # gateway's denials and the snapshot's destinations in the same
        # +{host:, port:}+ format, so an {EgressSecurityEvent} can directly
        # cite the snapshot's rule_id/entry_id for context.
        def allowlist_for(snapshot:)
          Array(snapshot&.destinations).map do |destination|
            { host: destination["host"], port: destination["port"] }.compact
          end
        end
      end
    end
  end
end
