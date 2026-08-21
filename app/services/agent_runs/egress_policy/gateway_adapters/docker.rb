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

        # Per-run allowlist path inside the shared gateway sidecar.
        # Each restricted run writes its own file (named after
        # +agent_run.id+) so concurrent restricted runs cannot
        # overwrite each other's policy — every restricted run reaches
        # the same gateway via the +egress-gateway+ Docker network
        # alias, and the sidecar process uses the file to filter
        # CONNECT/HTTP requests by host against the owning run's
        # destinations. See {#allowlist_config_path}.
        ALLOWLIST_CONFIG_DIR = "/etc/egress-gateway"

        # Per-run denial log path inside the sidecar. The gateway
        # appends a newline-delimited JSON line per denied request to
        # the run's file, so reads are naturally scoped to one run and
        # the file can be truncated after collection without losing
        # any other run's audit data. See {#denial_log_path}.
        DENIAL_LOG_DIR = "/var/log/egress-gateway"

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
        # writing a JSON config to {#allowlist_config_path}. The
        # per-run filename isolates this run's policy from concurrent
        # restricted runs sharing the same sidecar.
        def install_allowlist!(agent_run:, snapshot:, backend:)
          gateway_container = backend.get_container(GATEWAY_HOST)
          allowlist = allowlist_for(snapshot: snapshot)
          config = JSON.generate(
            agent_run_id: agent_run.id,
            allowlist: allowlist,
            installed_at: Time.current.iso8601
          )
          encoded = Base64.strict_encode64(config)
          path = allowlist_config_path(agent_run: agent_run)
          _stdout, stderr, exit_code = backend.exec_in_container(
            gateway_container,
            [ "sh", "-c", "echo '#{encoded}' | base64 -d > #{path}" ],
            wait: 5
          )
          unless exit_code&.zero?
            raise Gateway::UnavailableError,
              "failed to install allowlist on gateway '#{GATEWAY_HOST}': exit #{exit_code.inspect}: #{Array(stderr).join}"
          end
        rescue ::Docker::Error::DockerError => e
          raise Gateway::UnavailableError,
            "failed to install allowlist on gateway '#{GATEWAY_HOST}': #{e.message}"
        end

        # Reads denial events from the gateway sidecar's per-run
        # denial log {#denial_log_path} and truncates the file so a
        # subsequent retry of {Gateway#collect_denials!} does not
        # re-persist the same audit rows. Each line is a JSON object
        # with at least +host+, +port+, and +matched_rule+. Returns an
        # empty array when the log does not exist or the gateway has
        # not recorded any denials.
        def collect_denials(agent_run:, backend:)
          gateway_container = backend.get_container(GATEWAY_HOST)
          path = denial_log_path(agent_run: agent_run)
          stdout = read_denial_log(gateway_container: gateway_container, path: path, backend: backend)
          return [] unless stdout

          denials = stdout.join.each_line.filter_map do |line|
            parsed = JSON.parse(line.strip)
            { host: parsed["host"], port: parsed["port"],
              matched_rule: parsed["matched_rule"], scheme: parsed["scheme"] }
          rescue JSON::ParserError
            nil
          end
          truncate_per_run_log!(gateway_container: gateway_container, path: path, backend: backend)
          denials
        end

        # Path to the per-run allowlist config inside the shared
        # gateway sidecar. Each run's filename is its +agent_run.id+ so
        # two restricted runs sharing the sidecar never overwrite each
        # other's policy.
        def allowlist_config_path(agent_run:)
          "#{ALLOWLIST_CONFIG_DIR}/allowlist_#{agent_run.id}.json"
        end

        # Path to the per-run denial log inside the shared gateway
        # sidecar. Filename is keyed by +agent_run.id+ so a run only
        # ever reads its own denials, even when the sidecar is shared
        # across many concurrent restricted runs.
        def denial_log_path(agent_run:)
          "#{DENIAL_LOG_DIR}/denials_#{agent_run.id}.jsonl"
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

        private

        # Returns nil only when the denial log does not exist yet. Any other
        # read failure is a real operational error and must bubble so the
        # runner can log that the denial audit trail could not be drained.
        def read_denial_log(gateway_container:, path:, backend:)
          stdout, stderr, exit_code = backend.exec_in_container(
            gateway_container,
            [ "sh", "-c", "if [ ! -f #{path} ]; then exit 3; fi; cat #{path}" ],
            wait: 5
          )
          return nil if exit_code == 3
          return stdout if exit_code&.zero?

          raise Gateway::UnavailableError,
            "failed to read gateway denial log #{path}: exit #{exit_code.inspect}: #{Array(stderr).join}"
        end

        # Truncates the per-run denial log inside the gateway sidecar.
        # {#collect_denials} always calls this after a successful
        # read so a re-entry of {Gateway#collect_denials!} (e.g. a
        # retry from the runner's cleanup path) sees an empty log and
        # does not duplicate {EgressSecurityEvent} rows. Failures are
        # swallowed because the read already happened — a missed
        # truncation can at worst cause duplicate audit rows on the
        # next collect, never a missed denial.
        def truncate_per_run_log!(gateway_container:, path:, backend:)
          backend.exec_in_container(
            gateway_container,
            [ "sh", "-c", ": > #{path}" ],
            wait: 5
          )
          nil
        rescue ::Docker::Error::DockerError
          nil
        end
      end
    end
  end
end
