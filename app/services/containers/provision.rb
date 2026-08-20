# frozen_string_literal: true

require "base64"
require "digest"
require "docker-api"
require "json"
require "open3"
require "securerandom"
require "shellwords"
require "time"

module Containers
  # Service for provisioning, managing, and cleaning up Docker containers for agent execution.
  #
  # @example With auto-created workspace (git clone happens inside container)
  #   service = Containers::Provision.new(agent_run: agent_run)
  #   result = service.provision
  #   if result.success?
  #     service.execute("claude --version")
  #   end
  #   service.cleanup
  #
  # @example With explicit worktree path (legacy bind mount)
  #   service = Containers::Provision.new(
  #     agent_run: agent_run,
  #     worktree_path: "/var/paid/workspaces/123/456"
  #   )
  #
  # @example With block for automatic cleanup
  #   Containers::Provision.with_container(agent_run: agent_run) do |container|
  #     container.execute("claude code --task 'Fix the bug'")
  #   end
  #
  class Provision
    CompatibilityResult = Data.define(:compatible, :error_message)

    CODEX_NOTIFY_LINE = 'notify = ["sh", "-lc", "date +%s > /paid-heartbeat/.paid-heartbeat"]'
    HEARTBEAT_MOUNT_POINT = "/paid-heartbeat"
    MAX_STREAMING_LINE_BUFFER_BYTES = 64 * 1024

    # Maximum clock skew tolerance (seconds) between the Docker daemon's
    # `wait:` timer and Ruby's CLOCK_MONOTONIC when reclassifying a Docker
    # transport error as a timeout. Kept small to avoid false reclassification.
    DOCKER_TIMEOUT_SKEW_TOLERANCE = 0.5

    # Number of attempts the watchdog makes to stop a timed-out container.
    # The final attempt escalates to SIGKILL via Docker::Container#kill.
    WATCHDOG_STOP_ATTEMPTS = 3

    # Base error for all container service errors
    class Error < StandardError; end

    # Raised when container creation fails
    class ProvisionError < Error
      def initialize(msg = "Failed to provision container")
        super
      end
    end

    # Raised when command execution fails
    class ExecutionError < Error
      attr_reader :exit_code, :stdout, :stderr

      def initialize(msg, exit_code: nil, stdout: nil, stderr: nil)
        @exit_code = exit_code
        @stdout = stdout
        @stderr = stderr
        super(msg)
      end
    end

    # Raised when operation times out
    class TimeoutError < Error
      attr_reader :diagnostics

      def initialize(msg = "Operation timed out", diagnostics: {})
        @diagnostics = diagnostics
        super(msg)
      end
    end

    # Raised when no output is received within the startup timeout
    class StartupTimeoutError < TimeoutError
      def initialize(msg = "No output received within startup timeout", diagnostics: {})
        super(msg, diagnostics: diagnostics)
      end
    end

    # Raised when output stops flowing for longer than the idle timeout
    class IdleTimeoutError < TimeoutError
      def initialize(msg = "No output received within idle timeout", diagnostics: {})
        super(msg, diagnostics: diagnostics)
      end
    end

    # Raised when streaming output matches an abort pattern, indicating a
    # fatal runner error where the CLI is known to hang instead of exiting.
    #
    # `source:` distinguishes the two abort origins so callers classify them
    # correctly:
    #   - :pattern          — stderr/stdout matched a configured quota/rate-limit
    #                          pattern (e.g. KiloCode "Free tier limit reached").
    #                          This is a genuine rate-limit/quota signal.
    #   - :streaming_event  — a CLI streaming JSONL `error`/`turn.failed` event
    #                          (e.g. Codex `{"type":"error",...}`). This is a
    #                          generic execution failure, NOT a rate limit.
    # Misclassifying :streaming_event as a rate limit marks the runner
    # rate-limited and triggers unnecessary fallbacks (see run 24528).
    class OutputAbortError < Error
      attr_reader :matched_output, :source, :detail

      def initialize(msg = "Process aborted due to fatal output pattern", matched_output: nil, source: :pattern, detail: nil)
        @matched_output = matched_output
        @source = source.to_sym
        @detail = detail
        super(msg)
      end
    end

    # Raised when a server-side Codex refresh response cannot be materialized
    # into a usable Codex auth.json (blank/non-Codex payload, or missing the
    # access token a refresh must yield). Raised before the canonical
    # RunnerCredential is touched so a malformed upstream exchange is treated as
    # a failed refresh instead of bricking the stored credential (#2962 review).
    class InvalidCodexRefreshResponse < Error
      attr_reader :reason

      def initialize(msg = "Codex refresh response is not a usable auth.json", reason: nil)
        @reason = reason
        super(msg)
      end
    end

    # Bundles watchdog shared state (mutex, refs, timeouts) into a single
    # object to keep start_watchdog's parameter list under 4.
    WatchdogContext = Struct.new(
      :container, :mutex, :output_received_ref, :last_activity_ref,
      :exec_completed_ref, :timeout_reason_setter,
      :startup_timeout, :idle_timeout, :wall_clock_timeout, :started_at_ref,
      :heartbeat_path,
      keyword_init: true
    )

    # Bundles timeout-check state shared between raise_if_watchdog_timeout!
    # and check_deadline_exceeded! to keep their parameter lists under 4.
    TimeoutCheckState = Struct.new(
      :mutex, :timeout_reason_ref, :startup_timeout, :idle_timeout,
      :timeout, :started_at, :heartbeat_path, :output_received_ref, :last_activity_ref,
      keyword_init: true
    )

    CodexAuthMount = Struct.new(:host_path, :config_path, keyword_init: true)

    # File locks to serialize Codex OAuth refreshes when multiple runs share
    # the same host-backed auth.json. The lock key is derived from the
    # credential directory so unrelated Codex homes do not block each other.
    # Lock path prefix comes from AgentHarness::Providers::Codex#auth_lock_config.

    # Default resource limits (per issue #23 requirements)
    DEFAULTS = {
      memory_bytes: 4 * 1024 * 1024 * 1024, # 4GB RAM default; overridden by UserSetting#container_memory_bytes
      cpu_quota: 200_000,                        # 2 CPUs (100_000 per CPU)
      pids_limit: 500,                           # 500 process limit
      timeout_seconds: 3600,                     # 1 hour default timeout
      tmpfs_tmp_size: 1024 * 1024 * 1024,        # 1GB for /tmp
      tmpfs_cache_size: 512 * 1024 * 1024,       # 512MB for /home/agent/.cache
      tmpfs_codex_size: 256 * 1024 * 1024,       # 256MB for /home/agent/.codex
      image: Containers::ImageResolver::BASE_IMAGE,
      user: "agent",
      workspace_mount: "/workspace"
    }.freeze

    attr_reader :agent_run, :project, :worktree_path, :container, :workspace_volume, :pool_entry, :heartbeat_dir_host, :backend

    def self.network_for(agent_run:)
      new(agent_run: agent_run).network_name
    end

    # Ensures the specified Docker network exists (for sidecar provisioners
    # that need network readiness before creating containers), creating the
    # restricted +paid_agent+ network if missing. Delegates to
    # +NetworkPolicy.ensure_network!+ so +NetworkPolicy+ stays the single
    # source of truth for Docker network lifecycle (RDR-054). The sidecar
    # provisioners run in workflow steps 1.5-1.7, before the runner provisions
    # the agent container in step 2, so a pure existence check would fail on a
    # fresh or remote Docker host where the network has not been created yet.
    def self.ensure_network!(network:, backend: Containers.backend)
      NetworkPolicy.ensure_network!(network: network, backend: backend)
    end

    # Builds the provider-neutral +NetworkingPolicy+ for an agent run + project
    # pair using the same subscription-auth / direct-outbound heuristics the
    # legacy +#network_contract+ path uses. Construction is side-effect-free:
    # container options resolve lazily (see +#options+), so deriving the policy
    # does not pay the user-setting/image resolution cost of a full provision
    # (RDR-054).
    #
    # @param egress_profile [Symbol, nil] optional egress profile from RDR-055
    #   (:locked | :research | :open). When nil, the policy defaults to
    #   +:locked+ (the safe production default).
    # @return [ExecutionRunners::NetworkingPolicy]
    def self.networking_policy_for(agent_run:, project:, egress_profile: nil)
      service = new(agent_run: agent_run, project: project)
      service.networking_policy_with_egress_profile(egress_profile)
    end

    def self.codex_notify_line
      CODEX_NOTIFY_LINE
    end

    # @spec EXECUTION-ISOLATION-004
    def self.compatibility_for(agent_run:, backend:, worktree_path: nil)
      agent_run.execution_ingress_policy.validate_supported!
      service = new(agent_run: agent_run, worktree_path: worktree_path, backend: backend)
      # record_telemetry: false — compatibility_for is called for every candidate
      # host during queue scheduling (before any run is claimed), so skipping
      # RunnerAuthAttempt writes and the associated filesystem probes avoids
      # N × (DB writes + filesystem probes) per queue pass. Telemetry is still
      # recorded during the actual provision call.
      service.send(:validate_backend_mount_support!, record_telemetry: false)
      CompatibilityResult.new(compatible: true, error_message: nil)
    rescue ProvisionError, ExecutionRunners::ProvisionError => e
      CompatibilityResult.new(compatible: false, error_message: e.message)
    end

    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param worktree_path [String, nil] Path to an existing worktree to bind-mount.
    #   When nil, a Docker named volume is created for in-container git clone.
    # @param options [Hash] Override default container options
    # @option options [Integer] :memory_bytes Memory limit in bytes
    # @option options [Integer] :cpu_quota CPU quota (100_000 per CPU)
    # @option options [Integer] :pids_limit Maximum number of processes
    # @option options [Integer] :timeout_seconds Default command timeout
    # @option options [Integer] :tmpfs_codex_size Size of the writable ~/.codex tmpfs
    # @option options [String] :image Docker image to use
    # @param networking_policy [ExecutionRunners::NetworkingPolicy, nil] optional
    #   provider-neutral networking policy (RDR-054). When supplied, the
    #   provisioner uses it directly as the source of truth for network name
    #   and proxy URL, instead of recomputing +network_contract+ from
    #   subscription-auth / direct-outbound heuristics. The runner is the
    #   intended caller — direct callers should leave it nil and keep the
    #   existing fallback behavior.
    def initialize(agent_run: nil, project: nil, worktree_path: nil, pool_entry: nil, workspace_volume: nil,
      backend: Containers.backend, networking_policy: nil, credential_maintenance: false, **options)
      raise ArgumentError, "agent_run or project is required" if agent_run.nil? && project.nil? && !credential_maintenance

      if options.key?(:network)
        Rails.logger.warn(
          message: "container_manager.container.network_option_ignored",
          agent_run_id: agent_run&.id,
          hint: "The :network option is ignored; containers use the network selected by runner auth mode"
        )
        options.delete(:network)
      end
      @agent_run = agent_run
      @project = project || agent_run&.project
      @worktree_path = worktree_path
      @pool_entry = pool_entry
      @workspace_volume = workspace_volume
      @preview_tunnel_option = options.delete(:preview_tunnel)
      @pool_mode = options.delete(:pool_mode) { false }
      @networking_policy = networking_policy
      @raw_options = options
      @backend = backend
      @container = nil
      @heartbeat_age_cache = {}
      @heartbeat_age_cache_mutex = Mutex.new
      @heartbeat_dir_host = nil
    end

    # Resolves the effective container options on first access. Deferred from
    # +initialize+ so callers that only need policy/eligibility state (e.g.
    # +networking_policy_for+, +compatibility_for+) do not pay the user-setting
    # and image resolution cost (DB queries plus profile lookups) that only
    # provisioning actually needs.
    def options
      @options ||= begin
        base_options = DEFAULTS.merge(resolve_user_setting_overrides)
        image_selection = resolve_runtime_image_selection(default_image: base_options[:image])
        @runtime_image_selection = image_selection

        base_options
          .merge(image: image_selection.image)
          .merge(@raw_options.except(:image))
      end
    end

    # The runtime image selection backing #options — warm-time provenance for
    # a claimed pool entry, a fresh selection otherwise. Nil until #options
    # has been resolved. PoolManager persists this on the pool entry at warm
    # time so claims attribute the digest the container actually runs.
    attr_reader :runtime_image_selection

    # Provisions a new container with security hardening.
    # Ensures the selected network exists before creating the container,
    # and applies firewall rules for restricted proxy-mode runs after start.
    # @spec CONTAINER-RUNTIME-001
    #
    # Signal-aware: a rescue clause for SignalException (e.g. Interrupt from
    # Thread#raise on cancellation) runs cleanup before re-raising so the
    # half-created container and workspace volume are not leaked. Without
    # this clause, StandardError rescues below bypass an in-flight cancel
    # because SignalException inherits from Exception, not StandardError.
    #
    # @return [Result] Result object with success/failure status
    def provision
      agent_run&.execution_ingress_policy&.validate_supported!
      log_system("container.provision.start", image: options[:image], backend: backend.identifier)

      validate_backend_mount_support!
      prepare_heartbeat_dir! if backend.supports_host_paths?
      prepare_workspace!
      ensure_network!
      @container = create_container
      start_container
      fix_all_ownership!
      seed_opencode_database!
      seed_kilo_database!
      seed_codex_credentials!
      seed_gemini_credentials!
      seed_copilot_credentials!
      seed_claude_credentials!
      seed_preview_tunnel_config!
      apply_network_restrictions!

      log_system("container.provision.success", container_id: container.id)
      Result.success(container_id: container.id, container_host: backend.container_host_for(container))
    rescue Docker::Error::DockerError => e
      log_system("container.provision.failed", error: e.message)
      cleanup
      cleanup_workspace_volume
      raise ProvisionError, "Docker error: #{e.message}"
    rescue StandardError => e
      log_system("container.provision.failed", error: e.message)
      cleanup
      cleanup_workspace_volume
      raise
    rescue SignalException => e
      # Cancellation signal (typically Interrupt from Thread#raise in the
      # activity's drain path) lands here. run the same cleanup as the
      # StandardError rescue so a half-provisioned container and its
      # workspace volume are not orphaned, then re-raise so the worker
      # thread exits with the original signal.
      log_system("container.provision.interrupted", signal: e.class.name)
      cleanup
      cleanup_workspace_volume
      raise
    end

    def activate_preview_tunnel!(app_port:)
      raise ArgumentError, "app_port is required" if app_port.blank?
      return unless preview_tunnel?

      @preview_tunnel = Previews::TunnelManager::TunnelDefinition.new(
        session_token: preview_tunnel.session_token,
        tunnel_port: preview_tunnel.tunnel_port,
        app_port: app_port
      )

      seed_preview_tunnel_config!
    end

    # Executes a command inside the container and captures output.
    #
    # A background watchdog thread monitors output activity when +startup_timeout+
    # or +idle_timeout+ is set. If the timeout fires, the watchdog stops the
    # container to unblock the exec HTTP stream, and the main thread raises the
    # appropriate error after exec returns.
    #
    # @param command [String, Array<String>] Command to execute
    # @param timeout [Integer] Timeout in seconds (default from options)
    # @param startup_timeout [Integer, nil] Max seconds to wait for first output.
    #   Raises +StartupTimeoutError+ if no output is received within this window.
    # @param idle_timeout [Integer, nil] Max seconds between output chunks after
    #   the first output has been received. Raises +IdleTimeoutError+ if output
    #   stops flowing for longer than this duration.
    # @param stream [Boolean] Whether to stream output to agent logs
    # @param env [Hash] Environment variables for the exec invocation
    # @param heartbeat_path [String, nil] Optional heartbeat file path.
    #   Host-visible paths are read directly. Container-only paths under
    #   /paid-heartbeat are probed with Docker exec so volume-backed
    #   workspaces can still suppress false startup/idle timeouts during
    #   long, silent LLM inference. Agents can touch this file (e.g. via
    #   Claude Code +PostToolUse+ or Codex +notify+ hooks) to signal
    #   "still working" and avoid startup/idle timeouts.
    # @yieldparam stream_type [Symbol] +:stdout+ or +:stderr+
    # @yieldparam chunk [String] output chunk forwarded as the container
    #   exec stream emits it, after UTF-8/null-byte normalization. The block
    #   runs inside the backend streaming callback alongside the watchdog
    #   bookkeeping, so it must stay fast; a slow consumer throttles output
    #   pumping and the shared timeout checks. Exceptions raised by the block
    #   propagate out of +#execute+ and abort the run.
    # @return [Result] Result with stdout, stderr, and exit_code
    # @raise [StartupTimeoutError] when no output is received within +startup_timeout+ seconds
    # @raise [IdleTimeoutError] when output stops for more than +idle_timeout+ seconds
    # @raise [TimeoutError] when total wall-clock +timeout+ is exceeded
    # @spec CONTAINER-RUNTIME-019
    def execute(command, timeout: nil, startup_timeout: nil, idle_timeout: nil, stream: true, env: {}, preparation: nil, heartbeat_path: nil, abort_patterns: nil, &block)
      raise ProvisionError, "Container not provisioned" unless container

      with_codex_auth_lock(command) { execute_unlocked(command, timeout:, startup_timeout:, idle_timeout:, stream:, env:, preparation:, heartbeat_path:, abort_patterns:, &block) }
    end

    def network_name
      network_contract.network
    end

    # Derives the provider-neutral +ExecutionRunners::NetworkingPolicy+ for
    # this provision using the subscription-auth / direct-outbound heuristics
    # (the same source of truth as the legacy +#network_contract+ path). Public
    # so +networking_policy_for+ can compute the policy without reaching into
    # private detection methods.
    def derived_networking_policy
      @derived_networking_policy ||= if subscription_auth?
        ExecutionRunners::NetworkingPolicy.subscription_auth
      elsif direct_outbound_runner?
        ExecutionRunners::NetworkingPolicy.direct_outbound
      else
        ExecutionRunners::NetworkingPolicy.proxy_restricted
      end
    end

    # Returns a policy derived from {#derived_networking_policy} with the given
    # RDR-055 egress profile applied. The profile is carried through
    # +ExecutionRunners::NetworkingPolicy+ so orchestration code does not need
    # to reference Docker- or network-specific concepts to set it. Defaults to
    # +:locked+ when +egress_profile+ is nil.
    # @spec CONTAINER-RUNTIME-020
    def networking_policy_with_egress_profile(egress_profile)
      base = derived_networking_policy
      return base if egress_profile.nil?

      base.with(egress_profile: egress_profile)
    end

    private def abort_pattern_candidates(stream_type, normalized_chunk, stdout_buffer:)
      return [ normalized_chunk ] unless stream_type == :stdout

      combined = stdout_buffer << normalized_chunk.to_s
      lines = combined.lines(chomp: true)
      complete_lines = combined.end_with?("\n") ? lines : lines[0...-1]
      stdout_buffer.replace(combined.end_with?("\n") ? "" : lines.last.to_s)

      candidates = complete_lines.filter_map do |line|
        if structured_jsonl_line?(line)
          structured_jsonl_abort_candidate(line)
        else
          line
        end
      end
      if stdout_buffer.present?
        if stdout_buffer.lstrip.start_with?("{")
          if structured_jsonl_line?(stdout_buffer)
            candidate = structured_jsonl_abort_candidate(stdout_buffer)
            candidates << candidate if candidate.present?
            stdout_buffer.clear
          elsif complete_json_object?(stdout_buffer) || !potential_json_object_prefix?(stdout_buffer)
            candidates << stdout_buffer.dup
            stdout_buffer.clear
          end
        else
          candidates << stdout_buffer.dup
          stdout_buffer.clear
        end
      end

      candidates
    end

    private def structured_jsonl_line?(line)
      structured_jsonl_payload(line).present?
    end

    private def structured_jsonl_abort_candidate(line)
      payload = structured_jsonl_payload(line)
      return nil unless payload

      type = payload["type"].to_s
      failure_text = structured_jsonl_failure_text(payload)
      return nil if failure_text.blank?

      return failure_text if type.match?(/(?:^|[._-])(error|failed|failure|rate_limit|rate_limited)(?:$|[._-])/i)

      nil
    end

    private def structured_jsonl_payload(line)
      stripped = line.to_s.strip
      return nil if stripped.blank?

      parsed = JSON.parse(stripped)
      return nil unless parsed.is_a?(Hash) && parsed["type"].present?

      parsed
    rescue JSON::ParserError, TypeError
      nil
    end

    private def complete_json_object?(text)
      stripped = text.to_s.strip
      return false unless stripped.start_with?("{")

      parsed = JSON.parse(stripped)
      parsed.is_a?(Hash)
    rescue JSON::ParserError, TypeError
      false
    end

    private def potential_json_object_prefix?(text)
      stripped = text.to_s.lstrip
      stripped.match?(/\A\{\s*(?:"|\z)/)
    end

    private def final_abort_pattern_candidate(stdout_buffer)
      return nil if stdout_buffer.blank?

      if structured_jsonl_line?(stdout_buffer)
        structured_jsonl_abort_candidate(stdout_buffer)
      elsif stdout_buffer.lstrip.start_with?("{")
        stdout_buffer
      else
        stdout_buffer
      end
    end

    private def structured_jsonl_failure_text(payload)
      [
        payload["message"],
        payload.dig("error", "message"),
        payload["output"],
        payload["stderr"],
        payload.dig("item", "output"),
        payload.dig("item", "stderr"),
        payload.dig("item", "message")
      ].find(&:present?)
    end

    private def execute_unlocked(command, timeout: nil, startup_timeout: nil, idle_timeout: nil, stream: true, env: {}, preparation: nil, heartbeat_path: nil, abort_patterns: nil, &block)
      timeout ||= options[:timeout_seconds]
      cmd_array = close_stdin_for_codex_exec(command)
      cmd_array = cmd_array.is_a?(Array) ? cmd_array : [ "sh", "-c", cmd_array ]
      exec_options = { wait: timeout, Env: exec_environment(env) }
      cleanup_steps = apply_execution_preparation(preparation, env: env)

      log_system("container.execute.start", command: command.to_s.encode("UTF-8", invalid: :replace).truncate(200))

      stdout_buffer = []
      stderr_buffer = []
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Watchdog state shared between the exec thread and watchdog thread.
      # The watchdog stops the container to unblock the exec HTTP stream
      # (Thread.raise is unreliable with Excon's blocking I/O), then sets
      # timeout_reason so the main thread can raise the right error.
      # exec_completed prevents late watchdog firing after exec returns.
      # All shared state is accessed under watchdog_mutex; the reason ref
      # lambda ensures raise_if_watchdog_timeout! reads the current value
      # rather than a stale snapshot captured at call time.
      watchdog_mutex = Mutex.new
      output_received = false
      last_activity_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exec_completed = false
      timeout_reason = nil # :startup, :idle, or :wall_clock, set by watchdog
      timeout_reason_ref = -> { timeout_reason }
      abort_matched_output = nil # set when an abort_pattern matches stderr
      stdout_abort_buffer = +""
      watchdog = nil
      streaming_event_processor = build_streaming_event_processor(command)
      streaming_abort_triggered = false
      streaming_abort_event_type = nil
      streaming_line_buffer = +""

      timeout_check = TimeoutCheckState.new(
        mutex: watchdog_mutex,
        timeout_reason_ref: timeout_reason_ref,
        startup_timeout: startup_timeout,
        idle_timeout: idle_timeout,
        timeout: timeout,
        started_at: started_at,
        heartbeat_path: heartbeat_path,
        output_received_ref: -> { output_received },
        last_activity_ref: -> { last_activity_at }
      )

      watchdog_ctx = WatchdogContext.new(
        container: container,
        mutex: watchdog_mutex,
        output_received_ref: -> { output_received },
        last_activity_ref: -> { last_activity_at },
        exec_completed_ref: -> { exec_completed },
        timeout_reason_setter: ->(reason) { timeout_reason = reason },
        startup_timeout: startup_timeout,
        idle_timeout: idle_timeout,
        wall_clock_timeout: timeout,
        started_at_ref: -> { started_at },
        heartbeat_path: heartbeat_path
      )

      begin
        watchdog = start_watchdog(watchdog_ctx)

        exec_result = backend.exec_in_container(container, cmd_array, **exec_options) do |stream_type, chunk|
          watchdog_mutex.synchronize do
            output_received = true
            last_activity_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          normalized_chunk = normalize_output_chunk(chunk)

          case stream_type
          when :stdout
            stdout_buffer << normalized_chunk
            log_output(:stdout, normalized_chunk) if stream

            # Parse streaming JSONL progress events from stdout to give the
            # watchdog semantic awareness of agent state (turn progress, token
            # usage, errors) beyond raw output monitoring.
            if streaming_event_processor
              streaming_line_buffer << normalized_chunk
              while (newline_idx = streaming_line_buffer.index("\n"))
                line = streaming_line_buffer.slice!(0, newline_idx + 1)
                action = streaming_event_processor.handle_line(line)
                case action
                when :abort
                  streaming_abort_triggered = true
                  streaming_abort_event_type ||= streaming_event_processor.last_event_type
                  log_system("container.execute.streaming_abort",
                    reason: "#{streaming_abort_event_type} event received")
                  begin
                    backend.stop_container(container, timeout: 0)
                  rescue Docker::Error::DockerError => e
                    log_system("container.execute.streaming_abort_stop_failed", error: e.message)
                  end
                end
              end

              trim_streaming_line_buffer!(streaming_line_buffer)
            end
          when :stderr
            stderr_buffer << normalized_chunk
            log_output(:stderr, normalized_chunk) if stream
          end

          yield(stream_type, normalized_chunk) if block_given?

          # Check both stdout and stderr against abort patterns — if the CLI
          # emits a fatal error but hangs instead of exiting, stop the container
          # immediately rather than waiting for the idle/wall-clock timeout.
          # JSON-mode CLIs (e.g. Codex --json) may emit fatal errors on stdout.
          if abort_patterns&.any? && abort_matched_output.nil?
            abort_pattern_candidates(stream_type, normalized_chunk, stdout_buffer: stdout_abort_buffer).each do |candidate|
              next unless abort_patterns.any? { |pat| candidate.match?(pat) }

              abort_matched_output = candidate
              log_system("container.execute.abort_pattern_matched",
                stream: stream_type.to_s,
                output: candidate.truncate(200))
              begin
                backend.stop_container(container, timeout: 0)
              rescue Docker::Error::DockerError => e
                log_system("container.execute.abort_stop_failed", error: e.message)
              end
              break
            end
          end
        end

        if abort_patterns&.any? && abort_matched_output.nil?
          candidate = final_abort_pattern_candidate(stdout_abort_buffer)
          if candidate.present? && abort_patterns.any? { |pat| candidate.match?(pat) }
            abort_matched_output = candidate
            log_system("container.execute.abort_pattern_matched",
              stream: "stdout",
              output: candidate.truncate(200))
            begin
              backend.stop_container(container, timeout: 0)
            rescue Docker::Error::DockerError => e
              log_system("container.execute.abort_stop_failed", error: e.message)
            end
          end
        end

        # Process any remaining partial line left in the streaming buffer.
        if streaming_event_processor && streaming_line_buffer.present?
          action = streaming_event_processor.handle_line(streaming_line_buffer)
          if action == :abort && !streaming_abort_triggered
            streaming_abort_triggered = true
            streaming_abort_event_type ||= streaming_event_processor.last_event_type
          end
          streaming_line_buffer.clear
        end

        # Signal the watchdog that exec has returned, then stop it immediately
        # to prevent late/false timeouts during post-processing.
        watchdog_mutex.synchronize { exec_completed = true }
        stop_watchdog(watchdog)

        # Check if streaming events triggered an abort (turn.failed / error).
        if streaming_abort_triggered
          raise OutputAbortError.new(
            "Process aborted: streaming #{streaming_abort_event_type || 'turn_failed'} event detected",
            matched_output: "streaming_event:#{streaming_abort_event_type || 'turn_failed'}",
            source: :streaming_event,
            detail: streaming_event_processor&.last_error_message
          )
        end

        # Check if we stopped the container due to an abort pattern match.
        # This takes precedence over timeout checks because the abort was
        # the actual cause of termination.
        if abort_matched_output
          raise OutputAbortError.new(
            "Process aborted: fatal output pattern detected",
            matched_output: abort_matched_output
          )
        end

        # Check if the watchdog stopped the container (exec returns normally
        # with a non-zero exit code when the process is killed).
        raise_if_watchdog_timeout!(timeout_check)

        # The watchdog polls periodically, so exec may return between ticks with a
        # deadline already exceeded. Check the deadline directly in the main thread.
        check_deadline_exceeded!(timeout_check, output_received: output_received, last_activity_at: last_activity_at)

        # container.exec returns [stdout_array, stderr_array, exit_code].
        # The third element is the actual exec exit code, unlike
        # container.info which reflects the main process state.
        exit_code = exec_result.is_a?(Array) ? exec_result[2] : fetch_exit_code

        stdout = stdout_buffer.join
        stderr = stderr_buffer.join

        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

        log_system("container.execute.complete", exit_code: exit_code, duration_ms: elapsed_ms)

        if exit_code == 0
          Result.success(stdout: stdout, stderr: stderr, exit_code: exit_code)
        else
          # Exit 137 (128 + SIGKILL) on a clean completion almost always means
          # the cgroup OOM killer fired — the container's memory limit (swap is
          # disabled) was exceeded. Inspect the container state so an OOM is
          # recorded distinctly instead of being indistinguishable from an
          # ordinary non-zero exit. Scoped to 137 so routine non-zero probe
          # exits (git rev-parse -> 128, test -f -> 1) do not pay for an extra
          # Docker inspect.
          oom = exit_code == 137 ? oom_exit_diagnostics : {}
          if oom[:oom_killed]
            log_system("container.execute.oom_killed",
              exit_code: exit_code, duration_ms: elapsed_ms,
              memory_limit_bytes: oom[:memory_limit_bytes], container_running: oom[:container_running])
          elsif exit_code == 137
            log_system("container.execute.sigkill",
              exit_code: exit_code, duration_ms: elapsed_ms,
              memory_limit_bytes: oom[:memory_limit_bytes], container_running: oom[:container_running])
          end
          Result.failure(
            error: "Command exited with code #{exit_code}",
            stdout: stdout,
            stderr: stderr,
            exit_code: exit_code,
            oom_killed: oom[:oom_killed] || false,
            memory_limit_bytes: oom[:memory_limit_bytes],
            container_running: oom[:container_running]
          )
        end
      rescue OutputAbortError
        log_partial_output(stdout_buffer, stderr_buffer)
        raise
      rescue StartupTimeoutError, IdleTimeoutError => e
        log_partial_output(stdout_buffer, stderr_buffer)
        timeout_value = e.is_a?(StartupTimeoutError) ? startup_timeout : idle_timeout
        log_system("container.execute.timeout",
          timeout_type: e.class.name.demodulize,
          timeout: timeout_value,
          **timeout_diagnostics(started_at, output_received, last_activity_at, heartbeat_path),
          **output_summary_diagnostics(stdout_buffer, stderr_buffer))
        raise
      rescue TimeoutError
        log_partial_output(stdout_buffer, stderr_buffer)
        raise
      rescue Docker::Error::DockerError => e
        # Log partial output first — raise_if_watchdog_timeout! may re-raise.
        log_partial_output(stdout_buffer, stderr_buffer)

        # Check if the Docker error was caused by a streaming abort (turn.failed/error)
        # stopping the container. This takes precedence over abort patterns and timeout
        # classification so the caller sees OutputAbortError, not a generic ExecutionError.
        if streaming_abort_triggered
          raise OutputAbortError.new(
            "Process aborted: streaming #{streaming_abort_event_type || 'turn_failed'} event detected",
            matched_output: "streaming_event:#{streaming_abort_event_type || 'turn_failed'}",
            source: :streaming_event,
            detail: streaming_event_processor&.last_error_message
          )
        end

        # Check if the Docker error was caused by an abort pattern stopping the
        # container. This takes precedence over timeout classification.
        if abort_matched_output
          raise OutputAbortError.new(
            "Process aborted: fatal output pattern detected",
            matched_output: abort_matched_output
          )
        end

        begin
          raise_if_watchdog_timeout!(timeout_check)
        rescue StartupTimeoutError, IdleTimeoutError => timeout_error
          timeout_value = timeout_error.is_a?(StartupTimeoutError) ? startup_timeout : idle_timeout
          log_system(
            "container.execute.timeout",
            timeout_type: timeout_error.class.name.demodulize,
            timeout: timeout_value,
            **timeout_diagnostics(started_at, output_received, last_activity_at, heartbeat_path),
            **output_summary_diagnostics(stdout_buffer, stderr_buffer)
          )
          raise
        end

        # If exec raised after the overall wall-clock deadline and the watchdog
        # has not already classified this as a startup/idle timeout, treat it
        # as a wall-clock timeout rather than a generic execution failure.
        begin
          check_deadline_exceeded!(timeout_check, output_received: output_received, last_activity_at: last_activity_at)
        rescue StartupTimeoutError, IdleTimeoutError => timeout_error
          timeout_value = timeout_error.is_a?(StartupTimeoutError) ? startup_timeout : idle_timeout
          log_system(
            "container.execute.timeout",
            timeout_type: timeout_error.class.name.demodulize,
            timeout: timeout_value,
            **timeout_diagnostics(started_at, output_received, last_activity_at, heartbeat_path),
            **output_summary_diagnostics(stdout_buffer, stderr_buffer)
          )
          raise
        end

        # The Docker API `wait:` parameter and the watchdog both track the
        # same wall-clock timeout. If Docker fires first, elapsed time from
        # Ruby's monotonic clock may still be fractionally below the timeout
        # threshold (clock skew between the Docker daemon and CLOCK_MONOTONIC).
        # Use a small fixed tolerance (0.5s) to cover typical clock skew
        # without being so wide that unrelated Docker errors get reclassified.
        # Clamp to at most half the timeout so short-timeout execs are safe.
        if timeout
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          tolerance = [ DOCKER_TIMEOUT_SKEW_TOLERANCE, timeout * 0.5 ].min
          if elapsed >= timeout - tolerance
            log_system("container.execute.timeout",
              timeout_type: "wall_clock",
              timeout: timeout,
              elapsed_seconds: elapsed.round(1),
              source: "docker_api_reclassified",
              **timeout_diagnostics(started_at, output_received, last_activity_at, heartbeat_path),
              **output_summary_diagnostics(stdout_buffer, stderr_buffer))
            raise TimeoutError, "Command timed out after #{timeout} seconds"
          end
        end

        log_system("container.execute.failed", error: e.message)

        begin
          container.refresh!
          cstate = container.info["State"] || {}
          log_system("container.execute.container_state",
            running: cstate["Running"],
            exit_code: cstate["ExitCode"],
            oom_killed: cstate["OOMKilled"],
            error: cstate["Error"],
            finished_at: cstate["FinishedAt"])
        rescue Docker::Error::DockerError
        end

        raise ExecutionError.new("Docker exec error: #{e.message}")
      ensure
        watchdog_mutex.synchronize { exec_completed = true }
        stop_watchdog(watchdog)
        # Persist turn metrics even on error paths so partial progress is recorded.
        safe_flush_streaming_metrics(streaming_event_processor)
        if cleanup_steps&.any?
          if $!
            # An exception is already propagating; attempt cleanup but swallow
            # failures so the original exception is not replaced.
            # cleanup_execution_preparation already logs and invalidates.
            safe_cleanup_execution_preparation(cleanup_steps, env: env)
          else
            cleanup_execution_preparation(cleanup_steps, env: env)
          end
        end
      end
    end

    def close_stdin_for_codex_exec(command)
      return command unless codex_exec_command?(command)

      parts = command.is_a?(Array) ? command : Shellwords.split(command.to_s)
      escaped = parts.map { |part| Shellwords.escape(part.to_s) }.join(" ")
      [ "sh", "-lc", "exec #{escaped} < /dev/null" ]
    end

    # Stops and removes the container, cleaning up resources.
    #
    # @param force [Boolean] Force kill if container doesn't stop gracefully
    # @param preserve_workspace_volume [Boolean] Skip removing the shared
    #   workspace volume — set by callers tearing down a stale container
    #   reference (e.g. ExecutionControlParkCleanupJob) when the run has
    #   since been re-dispatched to a new container that reuses the same
    #   named volume.
    # @return [void]
    def cleanup(force: false, preserve_workspace_volume: false)
      cleanup_heartbeat_dir!

      log_system("container.cleanup.start", container_id: container&.id)
      preview_tunnel_released = false

      if container
        begin
          stop_container(force: force)
          backend.delete_container(container, force: force, v: true)
          preview_tunnel_released = release_preview_tunnel_reservation!
          log_system("container.cleanup.success")
        rescue Docker::Error::DockerError => e
          log_system("container.cleanup.failed", error: e.message)
          begin
            backend.delete_container(container, force: true, v: true)
            preview_tunnel_released = release_preview_tunnel_reservation!
          rescue Docker::Error::DockerError
            # Container may already be gone
          end
        end
      end

      preview_tunnel_released ||= release_preview_tunnel_reservation!
      log_system("container.preview_tunnel_port_released", tunnel_port: preview_tunnel.tunnel_port) if preview_tunnel_released
      @container = nil
      cleanup_workspace_volume unless preserve_workspace_volume
      cleanup_claimed_pool_entry
    end

    # Checks if the container is currently running.
    #
    # @return [Boolean]
    def container_running?
      return false unless container

      container.refresh!
      container.info["State"]["Running"] == true
    rescue Docker::Error::DockerError
      false
    end

    # Inspects the container's post-exec state after an exit-137 (SIGKILL) to
    # determine whether the cgroup OOM killer fired. Docker only sets
    # State.OOMKilled when the kernel OOM killer killed the container, so it is
    # the authoritative signal; a bare 137 is otherwise ambiguous. Best-effort —
    # returns {} when the container is already gone.
    def oom_exit_diagnostics
      return {} unless container

      container.refresh!
      info = container.info || {}
      state = info["State"] || {}
      {
        oom_killed: state["OOMKilled"] == true,
        container_running: state["Running"],
        memory_limit_bytes: info.dig("HostConfig", "Memory")
      }
    rescue Docker::Error::DockerError => e
      log_system("container.execute.exit_state_unavailable", error: e.message)
      {}
    end

    # Inspects the container's current lifecycle state for status queries.
    # Aggregates the Docker state fields the runner translates into
    # {ExecutionRunners::ExecutionStatus} — running, exit code, OOM flag, and
    # memory limit — so status inspection stays in the Docker-aware service
    # rather than leaking `container.info["State"]` shapes into the runner.
    #
    # Returns an empty hash when the container is gone or inspection fails;
    # the runner maps that to the `:not_found` state.
    #
    # @return [Hash] { running:, exit_code:, oom_killed:, memory_limit_bytes: }
    def container_status
      return {} unless container

      container.refresh!
      info = container.info || {}
      state = info["State"] || {}
      {
        running: state["Running"] == true,
        # Docker reports ExitCode as 0 while a container is running and keeps
        # the previous exit code across restarts; normalize to nil so a running
        # workload is not misread as exited-with-0 (ExecutionStatus contract:
        # exit_code is nil while still running).
        exit_code: state["Running"] == true ? nil : state["ExitCode"],
        oom_killed: state["OOMKilled"] == true,
        memory_limit_bytes: info.dig("HostConfig", "Memory")
      }
    rescue Docker::Error::DockerError
      {}
    end

    def heartbeat_host_path
      return nil unless heartbeat_dir_host.present?

      File.join(heartbeat_dir_host, HeartbeatSetup::HEARTBEAT_FILENAME)
    end

    # Attaches an existing Docker container to this service instance.
    # Used by .reconnect to rehydrate container state without reaching into ivars.
    #
    # @param container [Docker::Container] The existing container
    # @return [self]
    def with_existing_container(container, workspace_volume: nil, pool_entry: nil)
      @container = container
      @workspace_volume = workspace_volume if workspace_volume.present?
      @pool_entry = pool_entry if pool_entry.present?
      restore_heartbeat_dir!
      self
    end

    # Reconnects to an existing container by its Docker ID.
    # Used to rehydrate container state across Temporal activities.
    #
    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param container_id [String] The Docker container ID
    # @param worktree_path [String, nil] Path to the git worktree (optional)
    # @return [Provision] The reconnected service instance
    # @raise [ProvisionError] When container cannot be found
    def self.reconnect(agent_run:, container_id:, worktree_path: nil, workspace_volume: nil, pool_entry: nil, **options)
      pool_entry ||= ContainerPoolEntry.claimed.find_by(agent_run: agent_run, container_id: container_id)
      host = pool_entry&.container_host || agent_run.container_host
      backend = Containers.backend_for(host)
      container = backend.get_container(container_id)
      workspace_volume ||= pool_entry&.workspace_volume

      new(
        agent_run: agent_run,
        worktree_path: worktree_path,
        workspace_volume: workspace_volume,
        pool_entry: pool_entry,
        backend: backend,
        **options
      )
        .with_existing_container(container, workspace_volume: workspace_volume, pool_entry: pool_entry)
    rescue Docker::Error::NotFoundError
      raise ProvisionError, "Container #{container_id} not found"
    rescue Docker::Error::DockerError => e
      raise ProvisionError, "Failed to reconnect to container: #{e.message}"
    end

    # Provisions a container, yields to block, then ensures cleanup.
    #
    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param worktree_path [String, nil] Path to the git worktree (optional)
    # @param options [Hash] Override default container options
    # @yield [Provision] The provisioned container service instance
    # @return [Object] The return value of the block
    def self.with_container(agent_run:, worktree_path: nil, **options)
      service = new(agent_run: agent_run, worktree_path: worktree_path, **options)
      service.provision
      yield service
    ensure
      begin
        service&.cleanup
      rescue StandardError
        # Swallow cleanup errors to avoid masking the original exception
      end
    end

    # Public entry point for the keep-warm job (RDR-041 Phase 3).
    # Checks whether a host-forwarded Claude subscription credential exists and
    # is near expiry, then delegates to the private refresh path.  Returns a
    # result hash the caller can log without reaching into private internals.
    #
    # @return [Hash] { refreshed: Boolean, reason: String }
    def keep_warm_claude_credentials!
      unless claude_subscription_auth?
        return { refreshed: false, reason: "no_subscription_auth" }
      end

      unless claude_credentials_near_expiry?
        return { refreshed: false, reason: "not_near_expiry", expiry: claude_native_credential_expiry }
      end

      refresh_result = claude_subscription_auth_provider.refresh(provisioner: self)
      { refreshed: refresh_result.performed?, reason: refresh_result.reason }
    end

    # Public boundary for subscription auth adapter delegation (RDR-041).
    def refresh_claude_subscription_credential!
      refresh_claude_credentials_if_near_expiry!
    end

    # Public boundary for Codex managed subscription auth adapter delegation
    # (RDR-041 / #2962). The Codex adapter delegates refresh and harvest to the
    # provisioner so provider-specific execution stays owned here while the
    # contract stays provider-neutral.
    def refresh_codex_managed_credential!(provision: false)
      refresh_codex_managed_credential_if_needed!(provision: provision)
    end

    def harvest_codex_managed_credential!
      harvest_codex_managed_credential_impl!
    end

    private

    def apply_execution_preparation(preparation, env:)
      return [] if preparation.nil? || preparation.empty?

      cleanup_steps = []
      preparation.file_writes.each do |write|
        cleanup_steps << materialize_preparation_file(write, env: env)
      end
      cleanup_steps
    rescue StandardError
      cleanup_execution_preparation(cleanup_steps, env: env)
      raise
    end

    def cleanup_execution_preparation(cleanup_steps, env:)
      # A stopped or removed container has no live filesystem to restore — its
      # writable layer is ephemeral and about to be torn down. Restoring into a
      # dead container only fails with "container is not running", masking the
      # real cause of the container's death behind a misleading "Failed to
      # restore prepared runtime state" terminal error. Skip the restore and
      # invalidate so the run's real outcome (the exec result, or the
      # container-death error from the exec path) stands.
      unless container_running?
        log_system("container.execute.preparation_cleanup_skipped_container_not_running", container_id: container&.id)
        invalidate_container_after_preparation_cleanup_failure!
        return
      end

      cleanup_error = nil

      Array(cleanup_steps).reverse_each do |step_env|
        # Intentionally keeps only the first error (cleanup_error ||= e) so the
        # caller sees the root-cause failure rather than a cascading one.
        cleanup_error ||= run_preparation_cleanup_step(step_env, env: env)
      end

      return unless cleanup_error

      # Capture whether the container died mid-restore before invalidating
      # (invalidate stops the container, which would make a later liveness
      # check always read false).
      container_died = container_died_error?(cleanup_error) || !container_running?

      invalidate_container_after_preparation_cleanup_failure!

      # Don't surface a terminal restore error for a container that died — that
      # is infrastructure failure handled by the orchestration, not a genuine
      # inability to restore real state.
      return if container_died

      raise cleanup_execution_error(cleanup_error)
    end

    def container_died_error?(error)
      message = error.respond_to?(:message) ? error.message : error.to_s
      message.to_s.match?(Containers::CONTAINER_NOT_RUNNING_PATTERN)
    end

    # Best-effort cleanup that never raises, for use in ensure blocks when
    # an exception is already propagating.
    def safe_cleanup_execution_preparation(cleanup_steps, env:)
      cleanup_execution_preparation(cleanup_steps, env: env)
    rescue ExecutionError
      log_system("container.execute.preparation_cleanup_swallowed", note: "swallowed to preserve original exception")
    end

    # Best-effort metrics persistence for ensure blocks. Streaming telemetry
    # should not replace the original execution failure or skip later cleanup.
    def safe_flush_streaming_metrics(streaming_event_processor)
      streaming_event_processor&.flush_metrics!
    rescue StandardError => e
      log_system("container.execute.streaming_metrics_flush_failed", error: e.message)
    end

    # Runs a single preparation cleanup step, returning the error on failure
    # or nil on success.
    #
    # When the container has already stopped (e.g. OOM-killed mid-run), Docker
    # raises an error whose message includes "is not running". There is nothing
    # left to restore in a dead container, so we treat that case as a no-op
    # rather than surfacing a terminal restore failure that would trip the
    # runner circuit breaker.
    def run_preparation_cleanup_step(step_env, env:)
      run_preparation_script(cleanup_script, env: env, script_env: step_env)
      nil
    rescue Docker::Error::DockerError, ExecutionError => e
      if e.message.match?(/is not running/i)
        log_system("container.execute.preparation_cleanup_skipped_dead_container", error: e.message)
        return nil
      end
      log_system("container.execute.preparation_cleanup_failed", error: e.message)
      e
    end

    def materialize_preparation_file(write, env:)
      target_path = expand_preparation_path(write.path)
      state_dir = "#{target_path}.paid-state-#{SecureRandom.hex(8)}"

      run_preparation_script(
        materialize_script(write.mode),
        env: env,
        script_env: {
          "PAID_PREPARATION_TARGET" => target_path,
          "PAID_PREPARATION_STATE_DIR" => state_dir,
          "PAID_PREPARATION_B64" => Base64.strict_encode64(write.content)
        }
      )

      {
        "PAID_PREPARATION_TARGET" => target_path,
        "PAID_PREPARATION_STATE_DIR" => state_dir
      }
    end

    def run_preparation_script(script, env:, script_env:)
      preparation_env = env.merge(script_env)
      exec_options = { wait: options[:timeout_seconds] }
      exec_options[:Env] = preparation_env.map { |key, value| "#{key}=#{value}" }
      stdout, stderr, exit_code = backend.exec_in_container(container, [ "sh", "-lc", script ], **exec_options)

      return if exit_code.to_i.zero?

      raise ExecutionError.new(
        [ stdout, stderr ].join.presence || "Preparation script exited with code #{exit_code}",
        exit_code: exit_code,
        stdout: stdout,
        stderr: stderr
      )
    end

    def expand_preparation_path(path)
      path.to_s.sub(/\A~(?=\/|$)/, "/home/agent")
    end

    # Matches agent-harness lstat-based snapshot semantics: stores the state type
    # (symlink, file, or missing), preserves symlink targets via readlink, backs
    # up regular files with cp -p, and rejects directories.
    def materialize_script(mode)
      chmod_line = mode ? "chmod #{format('%#o', mode)} \"$PAID_PREPARATION_TARGET\"" : ":"

      <<~SH.squish
        set -e &&
        mkdir -p "$(dirname "$PAID_PREPARATION_TARGET")" &&
        mkdir -p "$PAID_PREPARATION_STATE_DIR" &&
        if [ -L "$PAID_PREPARATION_TARGET" ]; then
          readlink "$PAID_PREPARATION_TARGET" > "$PAID_PREPARATION_STATE_DIR/symlink_target" &&
          printf symlink > "$PAID_PREPARATION_STATE_DIR/state" &&
          rm -f "$PAID_PREPARATION_TARGET";
        elif [ -d "$PAID_PREPARATION_TARGET" ]; then
          printf 'preparation target must be a regular file or symlink: %s\n' "$PAID_PREPARATION_TARGET" >&2 && exit 1;
        elif [ -e "$PAID_PREPARATION_TARGET" ]; then
          cp -p "$PAID_PREPARATION_TARGET" "$PAID_PREPARATION_STATE_DIR/backup" &&
          printf file > "$PAID_PREPARATION_STATE_DIR/state" &&
          rm -f "$PAID_PREPARATION_TARGET";
        else
          printf missing > "$PAID_PREPARATION_STATE_DIR/state";
        fi &&
        printf '%s' "$PAID_PREPARATION_B64" | base64 -d > "$PAID_PREPARATION_TARGET" &&
        #{chmod_line}
      SH
    end

    def cleanup_script
      <<~SH.squish
        set -e && cleanup_status=0 &&
        state_value=$(cat "$PAID_PREPARATION_STATE_DIR/state" 2>/dev/null || echo unknown) &&
        dir=$(dirname "$PAID_PREPARATION_TARGET") &&
        if [ -d "$PAID_PREPARATION_TARGET" ] && [ ! -L "$PAID_PREPARATION_TARGET" ]; then
          printf 'preparation target changed into a directory during execution: %s\n' "$PAID_PREPARATION_TARGET" >&2 && cleanup_status=1;
        elif [ "$state_value" = symlink ]; then
          mkdir -p "$dir" && rm -f "$PAID_PREPARATION_TARGET" &&
          ln -s -- "$(cat "$PAID_PREPARATION_STATE_DIR/symlink_target")" "$PAID_PREPARATION_TARGET" || cleanup_status=$?;
        elif [ "$state_value" = file ]; then
          if [ -f "$PAID_PREPARATION_STATE_DIR/backup" ]; then
            mkdir -p "$dir" && rm -f "$PAID_PREPARATION_TARGET" &&
            cp -p "$PAID_PREPARATION_STATE_DIR/backup" "$PAID_PREPARATION_TARGET" || cleanup_status=$?;
          else
            printf 'missing runtime preparation backup\n' >&2 && cleanup_status=1;
          fi;
        elif [ "$state_value" = missing ]; then
          rm -f "$PAID_PREPARATION_TARGET" || cleanup_status=$?;
        else
          cleanup_status=1;
        fi &&
        rm -rf "$PAID_PREPARATION_STATE_DIR" &&
        exit "$cleanup_status"
      SH
    end

    def invalidate_container_after_preparation_cleanup_failure!
      old_container_id = container&.id

      cleanup(force: true)
      return if old_container_id.blank?

      AgentRun.where(id: agent_run.id, container_id: old_container_id).update_all(container_id: nil)
      agent_run.container_id = nil if agent_run.container_id == old_container_id
      log_system("container.execute.invalidated_after_preparation_cleanup_failure", container_id: old_container_id)
    end

    def cleanup_execution_error(error)
      return error if error.is_a?(ExecutionError) && error.message.include?("Failed to restore prepared runtime state")

      ExecutionError.new(
        "Failed to restore prepared runtime state: #{error.message}",
        exit_code: error.respond_to?(:exit_code) ? error.exit_code : nil,
        stdout: error.respond_to?(:stdout) ? error.stdout : nil,
        stderr: error.respond_to?(:stderr) ? error.stderr : nil
      )
    end

    # Resolves user-configurable container settings from the project's UserSetting.
    # Returns a hash of overrides that sit between DEFAULTS and caller-supplied options.
    def resolve_user_setting_overrides
      return {} unless project

      settings = AgentRuns::UserSettingsResolver.call(
        project: project, strict: false
      )
      return {} unless settings

      overrides = {}
      overrides[:memory_bytes] = resolve_memory_limit_bytes(settings)
      overrides
    end

    # The existing language-aware resolver still chooses the requested
    # runtime/image profile (RDR-046). RDR-059 layers on the final selection:
    # development/test keep mutable tags for local iteration, while production
    # resolves the requested tag to an immutable digest and persists the
    # selection metadata on the run. The resolution order mirrors the audit
    # trail: a claimed warm-pool container reuses the selection persisted on
    # its entry at warm time, an already-provisioned non-pool run reuses its
    # own recorded selection across reconnects, and only then does a fresh
    # catalog resolution win. The catalog's default may have moved between
    # warm and claim (or between reconnect and re-execute), and the run's
    # provenance must describe the container it actually executes in.
    def resolve_runtime_image_selection(default_image:)
      # @spec IMMUTABLE-IMAGE-001, IMMUTABLE-IMAGE-002, IMMUTABLE-IMAGE-003
      selection = claimed_pool_entry_selection || recorded_run_selection || resolve_catalog_selection(default_image)
      agent_run&.record_runtime_image_selection!(selection.metadata)
      selection
    end

    def claimed_pool_entry_selection
      metadata = @pool_entry&.runtime_image_selection
      return if metadata.blank?

      Containers::RuntimeImageSelector::Result.from_metadata(metadata)
    end

    # A non-pool run that already provisioned keeps its recorded selection.
    # Reconnects resolve #options each time, and re-resolving against the
    # catalog can overwrite provenance with a digest the running container
    # does not use — the same warm/claim drift fixed for pool entries.
    def recorded_run_selection
      metadata = agent_run&.runtime_image_selection
      return if metadata.blank?

      Containers::RuntimeImageSelector::Result.from_metadata(metadata)
    end

    def resolve_catalog_selection(default_image)
      requested_image = @raw_options[:image].presence || resolve_requested_project_image || default_image
      Containers::RuntimeImageSelector.select(
        project: project,
        requested_image: requested_image,
        environment: Rails.env
      )
    end

    def resolve_requested_project_image
      return unless project

      Containers::ImageResolver.resolve(project)
    end

    # In manual mode the memory limit comes straight from
    # +container_memory_bytes+. In auto mode Paid derives the limit from the
    # learned AgentRunResourceProfile recommendation for this project's
    # runner/goal, falling back to the user-configured ceiling when no profile
    # has enough samples yet. The fallback ladder (specific → runner_goal →
    # project → account → global → default) lives in
    # AgentRunResourceProfiles::Resolve; we only clamp the resulting number
    # to the user-configured auto band.
    def resolve_memory_limit_bytes(settings)
      return settings.container_memory_bytes if settings.container_memory_limit_manual?

      resolution = AgentRunResourceProfiles::Resolve.call(
        project: project,
        runner_key: agent_run&.resource_profile_runner_key,
        goal: agent_run&.goal
      )

      recommended = resolution[:recommended_memory_limit_bytes].to_i
      # Treat "no profile found" (Resolve returns the built-in default) the
      # same as no sample so first-run deployments honor the user's
      # configured limit instead of silently switching to the global
      # 4 GB estimate. Return the manual value directly — do NOT clamp it
      # to the auto band — otherwise flipping to auto mode can quietly
      # shrink a user's explicit container_memory_bytes (e.g. a 20 GB
      # manual limit collapsing to the 16 GB default ceiling) before any
      # profile has been learned. The floor/ceiling band constrains
      # learned recommendations only.
      return settings.container_memory_bytes if recommended <= 0 || resolution[:source] == "default"

      clamp_auto_memory_limit(recommended, settings)
    end

    def clamp_auto_memory_limit(bytes, settings)
      floor = settings.container_memory_auto_floor_bytes.to_i
      floor = UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_FLOOR_BYTES if floor <= 0
      ceiling = settings.container_memory_auto_ceiling_bytes.to_i
      ceiling = UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_CEILING_BYTES if ceiling <= 0

      bytes.to_i.clamp(floor, ceiling)
    end

    def stop_container(force: false)
      return unless container_running?

      backend.stop_container(container, timeout: force ? 0 : 10)
    rescue Docker::Error::NotFoundError
      # Container was already removed between running? check and stop
    end

    # Copies credentials from the read-only host mount into the writable
    # ~/.claude tmpfs. Only `.credentials.json` is needed for subscription auth;
    # `settings.json` is intentionally excluded to prevent interactive model
    # defaults from leaking into agent runs.
    #
    # Phase 3 (RDR-041): attempts a keep-warm refresh-token exchange before
    # seeding when the credential is near expiry, so the container receives a
    # fresh token rather than one about to expire mid-run.
    def seed_claude_credentials!
      source_files = %w[.credentials.json]
      return unless claude_subscription_auth?

      if materialize_managed_claude_credentials!
        return
      end

      refresh_claude_credentials_if_near_expiry!

      # Prefer the source that actually contains the required credential file
      # so we don't set PAID_CLAUDE_SUBSCRIPTION_AUTH=1 without seeding creds.
      host = claude_config_host_path
      host_source = host.present? && File.file?(File.join(host, ".credentials.json"))
      seeded = if host_source
        seed_host_credentials!(
          staging_path: "/home/agent/.claude-host",
          target_path: "/home/agent/.claude",
          files: source_files,
          success_log_key: "container.claude_credentials_seeded",
          failure_log_key: "container.claude_credentials_seed_failed",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
        )
      else
        seed_local_credentials!(
          source_path: claude_local_config_path,
          target_path: "/home/agent/.claude",
          files: source_files,
          success_log_key: "container.claude_credentials_seeded",
          failure_log_key: "container.claude_credentials_seed_failed",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
        )
      end

      # Only tag the row as materialized when the seeding path actually wrote
      # the credential; otherwise the local-copy branch silently no-ops and a
      # host_forwarded row would lie about its outcome.
      record_auth_attempt!(
        runner_key: "claude",
        attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        result: seeded ? RunnerAuthAttempt::RESULT_MATERIALIZED : RunnerAuthAttempt::RESULT_FAILED,
        failure_reason: seeded ? nil : "no_host_credential_seeded",
        metadata: { source: host_source ? "host_mount" : "local_copy" }
      )
    end

    # Writes a minimal Codex config into the writable ~/.codex tmpfs so the
    # CLI uses API-key auth against Paid's OpenAI proxy instead of cached
    # ChatGPT credentials. This keeps containerized runs aligned with Paid's
    # runner configuration.
    def seed_codex_config!(auth_source: RunnerAuthAttempt::AUTH_SOURCE_API_KEY_PROXY)
      config_toml = codex_harness_provider.config_file_content(
        model_provider: "paid",
        base_url: "#{proxy_base_url}/api/proxy/openai",
        env_key: "OPENAI_API_KEY",
        wire_api: "responses"
      )
      # Pin a Paid-selected top-level model so the Codex CLI does not fall back
      # to its built-in default. The proxy config has no model of its own, so
      # without this the proxy auth path mirrors the host-config leak that
      # seed_sanitized_codex_config! guards against on the subscription path.
      # The model key must precede the [chatgpt] table to remain a top-level
      # TOML key.
      content = [ codex_notify_line, codex_model_config_line, config_toml ].compact.join("\n\n")

      write_container_file("/home/agent/.codex/config.toml", content)
      log_system("container.codex_config_seeded", auth_source: auth_source)
    rescue Docker::Error::DockerError => e
      log_system("container.codex_config_seed_failed", error: e.message, auth_source: auth_source)
    end

    # Returns a top-level `model = "..."` TOML line for the Paid-selected Codex
    # model, or nil when no model id resolves (leaving the CLI default in place).
    def codex_model_config_line
      model_id = codex_container_model_id
      return nil if model_id.blank?

      %(model = "#{toml_string_escape(model_id)}")
    end

    def seed_codex_credentials!
      # Managed path (RDR-041 / #2962): materialize auth.json from the canonical
      # encrypted RunnerCredential. No host bind mount is required.
      if codex_managed_credential_active? && materialize_managed_codex_credentials!
        seed_codex_managed_config!
        seed_codex_notify_hook!
        return
      end

      unless codex_subscription_auth_mount.present?
        if unshared_codex_subscription_auth?
          record_auth_attempt!(
            runner_key: "codex",
            attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
            auth_source: :host_forwarded,
            materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
            result: RunnerAuthAttempt::RESULT_FAILED,
            failure_reason: "auth_unshared_local_only",
            metadata: { source: "unshared_host_only" }
          )
          raise_unshared_codex_auth_error!
        end

        seed_codex_config!
        record_auth_attempt!(
          runner_key: "codex",
          attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
          auth_source: :api_key_proxy,
          materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_ENV,
          result: RunnerAuthAttempt::RESULT_MATERIALIZED,
          metadata: { source: "proxy_config" }
        )
        return
      end

      mount = codex_subscription_auth_mount
      log_system("container.codex_credentials_shared",
        source_path: mount.host_path,
        auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED)
      seeded = seed_local_credentials!(
        source_path: mount.config_path,
        target_path: "/home/agent/.codex",
        files: [ "auth.json" ],
        success_log_key: "container.codex_credentials_seeded",
        failure_log_key: "container.codex_credentials_seed_failed",
        auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
      )
      verify_container_file_present!(
        path: "/home/agent/.codex/auth.json",
        failure_log_key: "container.codex_credentials_seed_failed",
        error_message: "Codex subscription auth.json was not copied into the container",
        auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
      )
      seed_sanitized_codex_config!(source_path: mount.config_path)

      seed_codex_notify_hook!

      record_auth_attempt!(
        runner_key: "codex",
        attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        result: seeded ? RunnerAuthAttempt::RESULT_MATERIALIZED : RunnerAuthAttempt::RESULT_FAILED,
        failure_reason: seeded ? nil : "no_host_credential_seeded",
        metadata: { source: "host_mount" }
      )
    end

    # Writes a minimal Codex config.toml for the managed subscription path: only
    # the model pin the CLI should use. The notify hook is appended separately by
    # seed_codex_notify_hook!. No proxy/model_provider block — subscription auth
    # authenticates via the materialized auth.json.
    def seed_codex_managed_config!
      model_line = codex_model_config_line
      return if model_line.blank?

      write_container_file("/home/agent/.codex/config.toml", model_line)
      log_system("container.codex_config_seeded")
    rescue Docker::Error::DockerError => e
      log_system("container.codex_config_seed_failed", error: e.message)
    end

    # Writes a Codex config.toml derived from the host config but with
    # incompatible sections stripped. The host config may contain [projects.*]
    # map sections that newer Codex CLI versions reject ("invalid type: map,
    # expected a sequence"). For container runs, project trust is managed by
    # --skip-git-repo-check, so those sections are unnecessary.
    def seed_sanitized_codex_config!(source_path:)
      return unless source_path.present?

      source_file = File.join(source_path, "config.toml")
      return unless File.file?(source_file)

      content = File.read(source_file)
      sanitized = sanitize_codex_host_config(content)
      write_container_file("/home/agent/.codex/config.toml", sanitized)
      log_system("container.codex_config_sanitized")
    rescue Docker::Error::DockerError, SystemCallError => e
      log_system("container.codex_config_sanitization_failed", error: e.message)
    end

    def sanitize_codex_host_config(toml)
      sanitized = strip_codex_project_sections(toml)
      sanitized = strip_codex_top_level_model_settings(sanitized)
      model_line = codex_model_config_line

      model_line ? "#{model_line}\n#{sanitized}" : sanitized
    end

    def strip_codex_project_sections(toml)
      in_projects = false
      toml.lines.reject do |line|
        if line.match?(/\A\[projects/)
          in_projects = true
          next true
        end

        if in_projects
          if line.match?(/\A\[/) && !line.match?(/\A\[projects/)
            in_projects = false
            next false
          end

          next true
        end

        false
      end.join
    end

    def strip_codex_top_level_model_settings(toml)
      in_top_level = true
      toml.lines.reject do |line|
        in_top_level = false if line.match?(/\A\s*\[/)
        in_top_level && line.match?(/\A\s*model(?:_reasoning_effort)?\s*=/)
      end.join
    end

    def codex_container_model_id
      tier = agent_run&.model_selection&.tier.presence ||
        agent_run&.model_selection&.llm_model&.tier.presence ||
        "mid"
      defaults = Runners::DefaultTierModelIds.call(runner_key: "codex", auth_type: codex_container_auth_type)

      [ tier, "mid", "high", "low" ].uniq.filter_map { |candidate| defaults[candidate] }.first
    end

    def codex_container_auth_type
      subscription_runner = agent_run&.runner&.runner_key == "codex" && agent_run.runner.subscription?
      subscription_runner || codex_subscription_auth? ? "subscription" : Runners::DefaultTierModelIds::DEFAULT_AUTH_TYPE
    end

    def toml_string_escape(value)
      JSON.generate(value.to_s)[1...-1]
    end

    # Appends the Codex notify hook to config.toml inside the container.
    # For subscription auth, the base config may come from the host or local
    # copy and may include an older notify shape. This method rewrites the
    # notify command idempotently so the watchdog receives heartbeats during
    # Codex turns without leaving duplicate TOML keys.
    # Creates config.toml when subscription auth only provided auth.json.
    def seed_codex_notify_hook!
      escaped_notify = Shellwords.escape(codex_notify_line)
      result = backend.exec_in_container(
        container,
        [ "sh", "-lc", codex_notify_rewrite_script(escaped_notify) ],
        user: "agent"
      )
      exit_code = result.is_a?(Array) ? result[2].to_i : 0
      raise Docker::Error::DockerError, "config rewrite exited with #{exit_code}" unless exit_code == 0

      log_system("container.codex_notify_hook_seeded")
    rescue Docker::Error::DockerError => e
      log_system("container.codex_notify_hook_seed_failed", error: e.message)
    end

    def codex_notify_rewrite_script(escaped_notify_line)
      <<~SH.squish
        config=/home/agent/.codex/config.toml;
        touch "$config" 2>/dev/null || true;
        tmp="$(mktemp)";
        awk -v notify_line=#{escaped_notify_line} '
          BEGIN { in_notify = 0 }
          /^[[:space:]]*\\[notify\\][[:space:]]*$/ { in_notify = 1; next }
          in_notify && /^[[:space:]]*\\[[^]]+\\][[:space:]]*$/ { in_notify = 0 }
          in_notify { next }
          /^[[:space:]]*notify[[:space:]]*=/ { next }
          !inserted && /^[[:space:]]*\\[[^]]+\\][[:space:]]*$/ { print notify_line; print ""; inserted = 1 }
          { print }
          END { if (!inserted) { print ""; print notify_line } }
        ' "$config" > "$tmp" &&
        cat "$tmp" > "$config";
        status=$?;
        rm -f "$tmp";
        exit "$status"
      SH
    end

    # Serializes only Codex CLI executions that share a rotation-risk credential.
    # Other container commands keep full parallelism, and different credentials
    # map to different lockfiles.
    #
    # Uses a non-blocking lock with retries instead of indefinite blocking to
    # prevent a hung container from stalling all other runs sharing the same
    # credential. After lock_timeout_seconds, logs a warning and proceeds
    # without the lock — a concurrent OAuth refresh may fail with
    # refresh_token_reused, which Paid classifies as auth_expired and handles
    # via the standard runner fallback path.
    #
    # For a managed RunnerCredential (#2962) the lease is keyed on the
    # credential id and the rotated auth.json is harvested back into the
    # canonical credential after the run. For a host-backed auth.json the lease
    # is keyed on the source path and the rotated file is synced back to disk.
    def with_codex_auth_lock(command)
      return yield unless codex_auth_lock_required?(command)

      if codex_managed_credential_active?
        with_codex_managed_auth_lock { yield }
      else
        with_codex_host_auth_lock { yield }
      end
    end

    def with_codex_host_auth_lock
      lockfile = codex_auth_lockfile_path
      lock_timeout = codex_auth_lock_timeout
      lease_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      File.open(lockfile, File::WRONLY | File::CREAT, 0o600) do |f|
        log_system("container.codex_auth_lock.waiting", lockfile: lockfile, lock_timeout_seconds: lock_timeout)

        acquired = false
        acquired = acquire_lock_with_timeout(f, lock_timeout)

        if acquired
          log_system("container.codex_auth_lock.acquired", lockfile: lockfile)
          record_codex_lease_attempt!(state: RunnerAuthAttempt::LEASE_ACQUIRED, started_at: lease_started_at,
            auth_source: :host_forwarded,
            materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
            metadata: { lockfile: lockfile })
          result = yield
          sync_codex_auth_file_to_source!
          result
        else
          log_system("container.codex_auth_lock.timeout",
            lockfile: lockfile,
            lock_timeout_seconds: lock_timeout)
          log_system("container.codex_auth_sync_skipped_without_lock", source_path: codex_subscription_auth_source_path)
          record_codex_lease_attempt!(state: RunnerAuthAttempt::LEASE_TIMEOUT, started_at: lease_started_at,
            auth_source: :host_forwarded,
            materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
            metadata: { lockfile: lockfile, lock_timeout_seconds: lock_timeout })
          yield
        end
      ensure
        if acquired
          f.flock(File::LOCK_UN)
          acquired = false
          log_system("container.codex_auth_lock.released", lockfile: lockfile)
        end
      end
    end

    # Managed-credential lease (RDR-041 / #2962). The Codex CLI may rotate
    # auth.json in-container (ROTATION_CONTAINER_MAY_ROTATE), so runs sharing a
    # managed credential serialize on a per-credential lockfile and harvest the
    # rotated state back into the canonical RunnerCredential before releasing.
    def with_codex_managed_auth_lock
      lockfile = codex_managed_auth_lockfile_path
      lock_timeout = codex_auth_lock_timeout
      lease_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      File.open(lockfile, File::WRONLY | File::CREAT, 0o600) do |f|
        log_system("container.codex_auth_lock.waiting", lockfile: lockfile, lock_timeout_seconds: lock_timeout)

        acquired = false
        acquired = acquire_lock_with_timeout(f, lock_timeout)

        if acquired
          log_system("container.codex_auth_lock.acquired", lockfile: lockfile)
          record_codex_lease_attempt!(state: RunnerAuthAttempt::LEASE_ACQUIRED, started_at: lease_started_at,
            auth_source: :managed,
            materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
            runner_credential: codex_managed_runner_credential,
            metadata: { lockfile: lockfile })
          result = yield
          harvest_codex_managed_credential!
          result
        else
          log_system("container.codex_auth_lock.timeout",
            lockfile: lockfile,
            lock_timeout_seconds: lock_timeout)
          log_system("container.codex_managed_harvest_skipped_without_lock",
            credential_id: codex_managed_runner_credential&.id)
          record_codex_lease_attempt!(state: RunnerAuthAttempt::LEASE_TIMEOUT, started_at: lease_started_at,
            auth_source: :managed,
            materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
            runner_credential: codex_managed_runner_credential,
            metadata: { lockfile: lockfile, lock_timeout_seconds: lock_timeout })
          yield
        end
      ensure
        if acquired
          f.flock(File::LOCK_UN)
          acquired = false
          log_system("container.codex_auth_lock.released", lockfile: lockfile)
        end
      end
    end

    def record_codex_lease_attempt!(state:, started_at:, auth_source: :host_forwarded,
      materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
      runner_credential: nil, metadata: {})
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      result = case state
      when RunnerAuthAttempt::LEASE_ACQUIRED then RunnerAuthAttempt::RESULT_LEASE_ACQUIRED
      when RunnerAuthAttempt::LEASE_WAITED then RunnerAuthAttempt::RESULT_LEASE_WAITED
      when RunnerAuthAttempt::LEASE_TIMEOUT then RunnerAuthAttempt::RESULT_LEASE_TIMEOUT
      else RunnerAuthAttempt::RESULT_FAILED
      end

      record_auth_attempt!(
        runner_key: "codex",
        attempt_stage: RunnerAuthAttempt::STAGE_LEASE,
        auth_source: auth_source,
        materialization_mode: materialization_mode,
        runner_credential: runner_credential,
        lease_state: state,
        result: result,
        duration_ms: duration_ms,
        metadata: metadata
      )
    end

    def acquire_lock_with_timeout(file, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if file.flock(File::LOCK_EX | File::LOCK_NB)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if remaining <= 0
        sleep [ remaining, 0.5 ].min
      end
    end

    def codex_auth_lock_timeout
      config = codex_harness_provider.auth_lock_config
      timeout = config&.dig(:timeout)
      timeout.is_a?(Numeric) ? timeout : 30
    end

    def seed_opencode_database!
      return unless opencode_runner_requested?

      result = backend.exec_in_container(
        container,
        [ "sh", "-c",
          "if [ -d /opt/opencode-seed ]; then " \
          "cp -a /opt/opencode-seed/. /home/agent/.local/share/opencode/ && " \
          "chown -R agent:agent /home/agent/.local/share/opencode; " \
          "fi" ],
        user: "root"
      )
      exit_code = result.is_a?(Array) ? result[2].to_i : 0
      raise Docker::Error::DockerError, "opencode database seed exited with #{exit_code}" unless exit_code == 0

      log_system("container.opencode_database_seeded")
    rescue Docker::Error::DockerError => e
      log_system("container.opencode_database_seed_failed", error: e.message)
    end

    def opencode_runner_requested?
      return false unless agent_run

      runners = resolved_run_runner_candidates
      return runners.any? { |runner| runner.runner_key == "opencode" } if runners.any?

      RunnerSupport.runner_key_for_agent_type(agent_run.agent_type) == "opencode"
    end

    # Restores the pre-migrated Kilocode SQLite database into the runtime tmpfs.
    # The Kilocode CLI runs a slow "one time database migration" on its first
    # invocation in a fresh container; without this seed that migration runs
    # inside the runner smoke preflight and exceeds the preflight wall-clock
    # timeout, exhausting the runner. The build pre-migrates the DB into
    # /opt/kilo-seed (see docker/agent/Dockerfile); the ~/.local/share/kilo
    # tmpfs mount wipes the build-time copy, so it is restored after start.
    # Mirrors seed_opencode_database!.
    def seed_kilo_database!
      return unless kilocode_runner_requested?

      result = backend.exec_in_container(
        container,
        [ "sh", "-c",
          "if [ -d /opt/kilo-seed ]; then " \
          "cp -a /opt/kilo-seed/. /home/agent/.local/share/kilo/ && " \
          "chown -R agent:agent /home/agent/.local/share/kilo; " \
          "fi" ],
        user: "root"
      )
      exit_code = result.is_a?(Array) ? result[2].to_i : 0
      raise Docker::Error::DockerError, "kilo database seed exited with #{exit_code}" unless exit_code == 0

      log_system("container.kilo_database_seeded")
    rescue Docker::Error::DockerError => e
      log_system("container.kilo_database_seed_failed", error: e.message)
    end

    def kilocode_runner_requested?
      return false unless agent_run

      runners = resolved_run_runner_candidates
      return runners.any? { |runner| runner.runner_key == "kilocode" } if runners.any?

      RunnerSupport.runner_key_for_agent_type(agent_run.agent_type) == "kilocode"
    end

    def seed_gemini_credentials!
      return unless gemini_subscription_auth?
      if managed_subscription_runner_auth_enabled_for?("gemini") && gemini_managed_oauth_creds_json.present?
        write_container_file("/home/agent/.gemini/oauth_creds.json", gemini_managed_oauth_creds_json)
        log_system("container.gemini_credentials_seeded",
          source: "managed_native_config",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_MANAGED)
        record_auth_attempt!(
          runner_key: "gemini",
          attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
          auth_source: :managed,
          materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          runner_credential: gemini_managed_runner_credential,
          result: RunnerAuthAttempt::RESULT_MATERIALIZED,
          metadata: gemini_managed_secret.redacted_metadata.merge("source" => "managed_native_config")
        )
        return
      end

      source_files = %w[
        oauth_creds.json
        google_accounts.json
        settings.json
        installation_id
        state.json
        trustedFolders.json
        projects.json
      ]

      # Prefer the source that actually contains oauth_creds.json so we don't
      # set PAID_GEMINI_SUBSCRIPTION_AUTH=1 without seeding creds.
      host = gemini_config_host_path
      host_source = host.present? && File.file?(File.join(host, "oauth_creds.json"))
      seeded = if host_source
        seed_host_credentials!(
          staging_path: "/home/agent/.gemini-host",
          target_path: "/home/agent/.gemini",
          files: source_files,
          success_log_key: "container.gemini_credentials_seeded",
          failure_log_key: "container.gemini_credentials_seed_failed",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
        )
      else
        seed_local_credentials!(
          source_path: gemini_local_config_path,
          target_path: "/home/agent/.gemini",
          files: source_files,
          success_log_key: "container.gemini_credentials_seeded",
          failure_log_key: "container.gemini_credentials_seed_failed",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
        )
      end

      record_auth_attempt!(
        runner_key: "gemini",
        attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        result: seeded ? RunnerAuthAttempt::RESULT_MATERIALIZED : RunnerAuthAttempt::RESULT_FAILED,
        failure_reason: seeded ? nil : "no_host_credential_seeded",
        metadata: { source: host_source ? "host_mount" : "local_copy" }
      )
    end

    def seed_copilot_credentials!
      return unless copilot_subscription_auth?
      if managed_subscription_runner_auth_enabled_for?("copilot") && copilot_managed_config_json.present?
        write_container_file("/home/agent/.copilot/config.json", copilot_managed_config_json)
        log_system("container.copilot_credentials_seeded",
          source: "managed_native_config",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_MANAGED)
        record_auth_attempt!(
          runner_key: "copilot",
          attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
          auth_source: :managed,
          materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
          runner_credential: copilot_managed_runner_credential,
          result: RunnerAuthAttempt::RESULT_MATERIALIZED,
          metadata: copilot_managed_secret.redacted_metadata.merge("source" => "managed_native_config")
        )
        return
      end

      source_files = %w[
        config.json
        settings.json
        permissions-config.json
        mcp-config.json
        lsp-config.json
      ]

      host = copilot_config_host_path
      host_source = host.present? && File.file?(File.join(host, "config.json"))
      seeded = if host_source
        seed_host_credentials!(
          staging_path: "/home/agent/.copilot-host",
          target_path: "/home/agent/.copilot",
          files: source_files,
          success_log_key: "container.copilot_credentials_seeded",
          failure_log_key: "container.copilot_credentials_seed_failed",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
        )
      elsif copilot_local_config_path.present?
        seed_local_credentials!(
          source_path: copilot_local_config_path,
          target_path: "/home/agent/.copilot",
          files: source_files,
          success_log_key: "container.copilot_credentials_seeded",
          failure_log_key: "container.copilot_credentials_seed_failed",
          auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED
        )
      else
        false
      end

      record_auth_attempt!(
        runner_key: "copilot",
        attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        result: seeded ? RunnerAuthAttempt::RESULT_MATERIALIZED : RunnerAuthAttempt::RESULT_FAILED,
        failure_reason: seeded ? nil : "no_host_credential_seeded",
        metadata: { source: host_source ? "host_mount" : "local_copy" }
      )
    end

    def copilot_config_has_oauth_token?
      config_path = copilot_config_host_path || copilot_local_config_path
      return false unless config_path

      json_path = File.join(config_path, "config.json")
      return false unless File.file?(json_path)

      config = JSON.parse(File.read(json_path))
      config["oauth_token"] || config["oauthToken"] || config["token"] ||
        config.dig("auth", "token")
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES
      false
    end

    def resolve_copilot_github_token
      return @resolved_copilot_github_token if defined?(@resolved_copilot_github_token)

      @resolved_copilot_github_token =
        env_var_token || read_copilot_cli_access_token_from_host || gh_cli_token
    end

    def env_var_token
      %w[COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN].filter_map do |var|
        ENV[var].to_s.strip.presence
      end.first
    end

    def read_copilot_cli_access_token_from_host
      path = File.join(Dir.home, ".copilot-cli-access-token")
      return nil unless File.file?(path)

      File.read(path).strip.presence
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def gh_cli_token
      stdout, _stderr, status = Open3.capture3("gh", "auth", "token")
      return nil unless status.success?

      stdout.strip.presence
    rescue SystemCallError
      nil
    end

    def seed_host_credentials!(staging_path:, target_path:, files:, success_log_key:, failure_log_key:, auth_source: nil)
      copy_commands = files.map do |filename|
        "cp #{Shellwords.escape("#{staging_path}/#{filename}")} #{Shellwords.escape("#{target_path}/#{filename}")} 2>/dev/null"
      end

      backend.exec_in_container(container, [ "chown", "-R", "agent:agent", target_path ], user: "root")
      backend.exec_in_container(container, [ "sh", "-c", "#{copy_commands.join('; ')}; true" ], user: "agent")
      log_system(success_log_key, **auth_source_log_payload(auth_source))
      true
    rescue Docker::Error::DockerError => e
      log_system(failure_log_key, error: e.message, **auth_source_log_payload(auth_source))
      false
    end

    def seed_local_credentials!(source_path:, target_path:, files:, success_log_key:, failure_log_key:, auth_source: nil)
      return false if source_path.blank?

      backend.exec_in_container(container, [ "chown", "-R", "agent:agent", target_path ], user: "root")

      write_commands = []
      files.each do |filename|
        source_file = File.join(source_path, filename)
        next unless File.file?(source_file)

        encoded = Base64.strict_encode64(File.binread(source_file))
        dest = Shellwords.escape(File.join(target_path, filename))
        write_commands << "echo #{Shellwords.escape(encoded)} | base64 -d > #{dest}"
      end

      return false if write_commands.empty?

      backend.exec_in_container(container, [ "sh", "-lc", write_commands.join("; ") ], user: "agent")
      log_system(success_log_key, files_copied: write_commands.size, **auth_source_log_payload(auth_source))
      true
    rescue Docker::Error::DockerError, SystemCallError => e
      log_system(failure_log_key, error: e.message, **auth_source_log_payload(auth_source))
      false
    end

    def verify_container_file_present!(path:, failure_log_key:, error_message:, auth_source: nil)
      _stdout, stderr, status = backend.exec_in_container(
        container,
        [ "sh", "-lc", "test -s #{Shellwords.escape(path)}" ],
        user: "agent"
      )
      return if status.to_i.zero?

      log_system(failure_log_key, error: [ error_message, Array(stderr).join.presence ].compact.join(": "),
        path: path, **auth_source_log_payload(auth_source))
      raise ProvisionError, error_message
    rescue Docker::Error::DockerError => e
      log_system(failure_log_key, error: e.message, path: path, **auth_source_log_payload(auth_source))
      raise ProvisionError, error_message
    end

    # Batches all ownership fixes into a single container exec call.
    # Each individual tmpfs mount and the workspace directory need their
    # ownership set to agent:agent after container start. Running these
    # as a single shell script reduces Docker API round-trips from 12+
    # down to 1.
    def fix_all_ownership!
      dirs = [
        options[:workspace_mount],
        "/home/agent/.cache",
        "/home/agent/.gemini",
        "/home/agent/.cursor-agent",
        "/home/agent/.kilocode",
        "/home/agent/.config/kilocode",
        "/home/agent/.local/share/kilo",
        "/home/agent/.config/opencode",
        "/home/agent/.local/share/opencode",
        "/home/agent/.copilot"
      ]

      # ~/.codex gets non-recursive chown to preserve host-backed file ownership
      recursive_script = dirs.map { |d| "chown -R agent:agent #{Shellwords.escape(d)}" }.join("; ")
      script = "#{recursive_script}; chown agent:agent /home/agent/.codex"

      backend.exec_in_container(container, [ "sh", "-c", script ], user: "root")
      log_system("container.ownership_batch_fixed", dirs_count: dirs.size + 1)
    rescue Docker::Error::DockerError => e
      log_system("container.ownership_batch_failed", error: e.message)
      # Fall back to individual fixes for resilience
      fix_ownership_individually!
    end

    # Fallback that runs ownership fixes one at a time when the batched
    # approach fails. This preserves the original behavior where individual
    # failures are logged but do not prevent provisioning from continuing.
    def fix_ownership_individually!
      fix_workspace_ownership!
      fix_cache_tmpfs_ownership!
      fix_codex_tmpfs_ownership!
      fix_gemini_tmpfs_ownership!
      fix_cursor_tmpfs_ownership!
      fix_kilocode_tmpfs_ownership!
      fix_kilocode_config_tmpfs_ownership!
      fix_kilocode_data_tmpfs_ownership!
      fix_opencode_config_tmpfs_ownership!
      fix_opencode_data_tmpfs_ownership!
      fix_copilot_tmpfs_ownership!
    end

    # Ensures the bind-mounted /workspace is writable by the non-root agent user.
    # Docker bind mounts inherit host ownership which may not match the container
    # user. Running chown as root inside the container fixes this portably.
    def fix_workspace_ownership!
      backend.exec_in_container(
        container,
        [ "chown", "-R", "agent:agent", options[:workspace_mount] ],
        user: "root"
      )
    rescue Docker::Error::DockerError => e
      log_system("container.workspace_chown_failed", error: e.message)
    end

    # Fixes ownership of the ~/.cache tmpfs so the non-root agent user can
    # write to it. Tmpfs mounts are created as root-owned; tools like Codex CLI,
    # npm, and others expect to cache data here.
    def fix_cache_tmpfs_ownership!
      backend.exec_in_container(
        container,
        [ "chown", "-R", "agent:agent", "/home/agent/.cache" ],
        user: "root"
      )
    rescue Docker::Error::DockerError => e
      log_system("container.cache_chown_failed", error: e.message)
    end

    # Fixes ownership of the ~/.codex tmpfs so the non-root agent user can
    # write to it. Tmpfs mounts are created as root-owned.
    # Only chown the directory entry itself so host-backed auth/config file
    # binds keep their original ownership.
    def fix_codex_tmpfs_ownership!
      backend.exec_in_container(
        container,
        [ "chown", "agent:agent", "/home/agent/.codex" ],
        user: "root"
      )
    rescue Docker::Error::DockerError => e
      log_system("container.codex_chown_failed", error: e.message)
    end

    # Fixes ownership of the ~/.gemini tmpfs so the non-root agent user can
    # write to it. Tmpfs mounts are created as root-owned.
    def fix_gemini_tmpfs_ownership!
      fix_tmpfs_ownership!(".gemini")
    end

    # Fixes ownership of the ~/.cursor-agent tmpfs so the non-root agent user
    # can write to it. Tmpfs mounts are created as root-owned.
    def fix_cursor_tmpfs_ownership!
      fix_tmpfs_ownership!(".cursor-agent", log_key: "cursor_agent")
    end

    # Fixes ownership of the ~/.kilocode tmpfs so the non-root agent user can
    # write to it. Tmpfs mounts are created as root-owned.
    def fix_kilocode_tmpfs_ownership!
      fix_tmpfs_ownership!(".kilocode")
    end

    # Fixes ownership of the ~/.config/kilocode tmpfs so the non-root agent user
    # can write to it. Tmpfs mounts are created as root-owned.
    def fix_kilocode_config_tmpfs_ownership!
      fix_tmpfs_ownership!(".config/kilocode")
    end

    # Fixes ownership of the ~/.local/share/kilo tmpfs so the non-root agent
    # user can write to it. Tmpfs mounts are created as root-owned.
    def fix_kilocode_data_tmpfs_ownership!
      fix_tmpfs_ownership!(".local/share/kilo")
    end

    # Fixes ownership of the ~/.config/opencode tmpfs so the non-root agent user
    # can write to it. Tmpfs mounts are created as root-owned.
    def fix_opencode_config_tmpfs_ownership!
      fix_tmpfs_ownership!(".config/opencode")
    end

    # Fixes ownership of the ~/.local/share/opencode tmpfs so the non-root agent
    # user can write to it. Tmpfs mounts are created as root-owned.
    def fix_opencode_data_tmpfs_ownership!
      fix_tmpfs_ownership!(".local/share/opencode")
    end

    # Fixes ownership of the ~/.copilot tmpfs so the non-root
    # agent user can write to it. Tmpfs mounts are created as root-owned.
    def fix_copilot_tmpfs_ownership!
      fix_tmpfs_ownership!(".copilot")
    end

    # Fixes ownership of a tmpfs mount under /home/agent so the non-root
    # agent user can write to it. Tmpfs mounts are created as root-owned.
    #
    # @param subdir [String] The directory path under /home/agent (e.g. ".codex", ".config/opencode")
    # @param log_key [String, nil] Override for the log event name segment. When nil, derived from
    #   subdir by stripping the leading dot and replacing "/" with "_"
    #   (e.g. ".config/opencode" → "config_opencode", ".local/share/opencode" → "local_share_opencode").
    def fix_tmpfs_ownership!(subdir, log_key: nil)
      log_key ||= subdir.delete_prefix(".").tr("/", "_")
      backend.exec_in_container(
        container,
        [ "chown", "-R", "agent:agent", "/home/agent/#{subdir}" ],
        user: "root"
      )
    rescue Docker::Error::DockerError => e
      log_system("container.#{log_key}_chown_failed", error: e.message)
    end

    # Sets up the workspace for the container.
    # When a host-side worktree_path is provided, validates it exists for bind-mount.
    # When nil (or container-internal), creates a Docker named volume for in-container git clone.
    # Docker volumes live on the overlay2 disk, bypassing the VM root filesystem.
    # @spec EXECUTION-ISOLATION-001
    def prepare_workspace!
      if host_worktree_path.present?
        unless backend.supports_host_paths?
          raise ProvisionError,
            "Backend #{backend.identifier} does not support host-backed worktree paths: #{host_worktree_path}"
        end

        raise ProvisionError, "Worktree path does not exist: #{host_worktree_path}" unless File.directory?(host_worktree_path)
      else
        @workspace_volume ||= pooled_container? ? "paid-pool-workspace-#{pool_entry.id}" : "paid-workspace-#{agent_run.id}"
        begin
          backend.get_volume(@workspace_volume)
        rescue Docker::Error::NotFoundError
          backend.create_volume(@workspace_volume, volume_options)
        end
      end
    end

    def host_worktree_path
      return nil if worktree_path.blank?
      return nil if worktree_path == options[:workspace_mount]

      worktree_path
    end

    def preview_tunnel
      return nil unless @preview_tunnel_option.present?
      return @preview_tunnel if defined?(@preview_tunnel)

      @preview_tunnel = if @preview_tunnel_option.is_a?(Previews::TunnelManager::TunnelDefinition)
        @preview_tunnel_option
      else
        Previews::TunnelManager::TunnelDefinition.new(
          session_token: @preview_tunnel_option.fetch(:session_token),
          tunnel_port: @preview_tunnel_option.fetch(:tunnel_port),
          app_port: @preview_tunnel_option[:app_port]
        )
      end
    end

    public

    def preview_tunnel?
      preview_tunnel.present?
    end

    private

    def preview_tunnel_environment
      tunnel = preview_tunnel

      [
        "PAID_PREVIEW_TUNNEL_CONFIG_PATH=#{preview_tunnel_config_path}",
        "PAID_PREVIEW_TUNNEL_SERVICE_NAME=#{tunnel.service_name}",
        "PAID_PREVIEW_TUNNEL_PORT=#{tunnel.tunnel_port}"
      ]
    end

    def preview_tunnel_config_path
      "/home/agent/.paid-preview/rathole-client.toml"
    end

    def seed_preview_tunnel_config!
      return unless preview_tunnel?
      return unless preview_tunnel.app_port.present?

      backend.exec_in_container(container, [ "mkdir", "-p", File.dirname(preview_tunnel_config_path) ], user: "agent")
      write_container_file(preview_tunnel_config_path, preview_tunnel_client_config)
      start_preview_tunnel_client!
      log_system(
        "container.preview_tunnel_config_seeded",
        service_name: preview_tunnel.service_name,
        tunnel_port: preview_tunnel.tunnel_port
      )
    rescue Docker::Error::DockerError => e
      log_system("container.preview_tunnel_config_seed_failed", error: e.message)
      raise
    end

    def preview_tunnel_client_config
      Previews::TunnelManager.client_config(
        tunnel: preview_tunnel,
        backend: backend,
        restricted: network_contract.restricted?
      )
    end

    def start_preview_tunnel_client!
      backend.exec_in_container(
        container,
        [ "sh", "-lc", preview_tunnel_client_start_command ],
        user: "agent"
      )
    end

    def preview_tunnel_client_start_command
      log_path = "/tmp/paid-preview-tunnel-client.log"
      config_path = Shellwords.escape(preview_tunnel_config_path)

      "rathole --client #{config_path} > #{Shellwords.escape(log_path)} 2>&1 &"
    end

    def release_preview_tunnel_reservation!
      return false unless preview_tunnel?

      Previews::TunnelManager.release_port(key: preview_tunnel.session_token)
      true
    rescue StandardError => e
      log_system("container.preview_tunnel_port_release_failed", error: e.message)
      false
    end

    def write_container_file(path, content)
      encoded = Base64.strict_encode64(content)
      cmd = "echo #{Shellwords.escape(encoded)} | base64 -d > #{Shellwords.escape(path)}"
      backend.exec_in_container(container, [ "sh", "-lc", cmd ], user: "agent")
    end

    def prepare_heartbeat_dir!
      dir = File.join(Dir.tmpdir, "paid-heartbeat-#{SecureRandom.hex(8)}")
      FileUtils.mkdir_p(dir)
      @heartbeat_dir_host = dir
      File.chmod(0o777, dir)
      log_system("container.heartbeat_dir_prepared", path: dir)
    end

    HEARTBEAT_DIR_PATTERN = /\Apaid-heartbeat-[0-9a-f]{16}\z/

    def restore_heartbeat_dir!
      return if @heartbeat_dir_host.present?

      label = container.info&.dig("Config", "Labels", "paid.heartbeat_dir")
      return unless label.present? && valid_heartbeat_dir?(label)

      @heartbeat_dir_host = label
    rescue => e
      Rails.logger.warn(
        message: "container_manager.heartbeat_dir_restore_failed",
        agent_run_id: agent_run&.id,
        error: e.message
      )
    end

    def cleanup_heartbeat_dir!
      return unless @heartbeat_dir_host && valid_heartbeat_dir?(@heartbeat_dir_host)

      FileUtils.rm_rf(@heartbeat_dir_host)
      @heartbeat_dir_host = nil
    rescue => e
      Rails.logger.warn(
        message: "container_manager.heartbeat_cleanup_failed",
        agent_run_id: agent_run&.id,
        error: e.message
      )
    end

    def valid_heartbeat_dir?(path)
      return false unless path.is_a?(String) && path.start_with?("#{Dir.tmpdir}/")

      realpath = File.realpath(path) rescue nil
      return false unless realpath && realpath.start_with?("#{Dir.tmpdir}/")

      File.basename(realpath).match?(HEARTBEAT_DIR_PATTERN)
    end

    def cleanup_workspace_volume
      volume_name = @workspace_volume
      volume_name ||= "paid-workspace-#{agent_run.id}" if host_worktree_path.blank? && agent_run.present? && !pooled_container?
      return unless volume_name

      backend.delete_volume(backend.get_volume(volume_name, host: volume_host))
    rescue Docker::Error::NotFoundError
      # Volume already removed
    rescue => e
      Rails.logger.warn(
        message: "container_manager.workspace_cleanup_failed",
        agent_run_id: agent_run&.id,
        project_id: project.id,
        error: e.message
      )
    ensure
      @workspace_volume = nil
    end

    def cleanup_claimed_pool_entry
      return unless pool_entry&.status == "claimed"

      pool_entry.destroy!
      @pool_entry = nil
    end

    def volume_host
      return agent_run.container_host if agent_run&.container_host.present?
      return pool_entry.container_host if pool_entry&.container_host.present?
      return backend.container_host_for(container) if container

      nil
    end

    def volume_options
      labels = {
        "paid.managed" => "true",
        "paid.resource" => pooled_container? ? "container_pool_workspace" : "workspace_volume",
        "paid.project_id" => project.id.to_s
      }
      labels["paid.agent_run_id"] = agent_run.id.to_s if agent_run
      labels["paid.container_pool_entry_id"] = pool_entry.id.to_s if pool_entry

      {
        "Labels" => labels
      }
    end

    def container_labels
      labels = {
        "paid.project_id" => project.id.to_s
      }

      if pooled_container?
        labels["paid.container_pool"] = "true"
        labels["paid.container_pool_entry_id"] = pool_entry.id.to_s
      else
        labels["paid.agent_run_id"] = agent_run.id.to_s
      end

      labels["paid.heartbeat_dir"] = heartbeat_dir_host if heartbeat_dir_host
      if preview_tunnel?
        labels[Previews::TunnelManager::PREVIEW_TUNNEL_LABEL] = "true"
        labels[Previews::TunnelManager::PREVIEW_SESSION_TOKEN_LABEL] = preview_tunnel.session_token
        labels[Previews::TunnelManager::PREVIEW_SERVICE_NAME_LABEL] = preview_tunnel.service_name
        labels[Previews::TunnelManager::PREVIEW_TUNNEL_PORT_LABEL] = preview_tunnel.tunnel_port.to_s
      end
      labels
    end

    def create_container
      backend.create_container(container_config)
    end

    def start_container
      backend.start_container(container)
    end

    # Writable directories inside the container:
    #   /workspace          - bind mount of workspace dir (rw, for git clone and code changes)
    #   /paid-heartbeat     - host bind mount when supported, otherwise tmpfs (rw, for heartbeat touches)
    #   /tmp                - tmpfs (1GB, for scratch files)
    #   /home/agent/.cache  - tmpfs (512MB, for tool caches: Codex CLI, npm, etc.)
    #   /home/agent/.claude - tmpfs (256MB, for Claude CLI session/project data)
    #   /home/agent/.codex    - tmpfs (256MB, for Codex CLI config/session data)
    #   /home/agent/.gemini   - tmpfs (64MB, for Gemini CLI config/session data)
    #   /home/agent/.cursor-agent - tmpfs (64MB, for Cursor agent CLI config/session data)
    #   /home/agent/.kilocode - tmpfs (64MB, for Kilocode CLI plugin/session data)
    #   /home/agent/.config/kilocode - tmpfs (64MB, for Kilocode CLI config)
    #   /home/agent/.local/share/kilo - tmpfs (64MB, for Kilocode CLI data)
    #   /home/agent/.config/opencode         - tmpfs (64MB, for OpenCode CLI config)
    #   /home/agent/.local/share/opencode    - tmpfs (64MB, for OpenCode CLI data)
    #   /home/agent/.copilot                 - tmpfs (64MB, for GitHub Copilot CLI config)
    # All other paths are read-only via ReadonlyRootfs.
    def container_config
      {
        "Image" => options[:image],
        "name" => container_name,
        "User" => options[:user],
        "ReadonlyRootfs" => true,
        "CapDrop" => [ "ALL" ],
        "CapAdd" => [ "NET_RAW" ],
        "SecurityOpt" => [ "no-new-privileges:true" ],
        "HostConfig" => host_config,
        "Env" => environment_variables,
        "WorkingDir" => options[:workspace_mount],
        "Labels" => container_labels,
        "Tty" => false,
        "OpenStdin" => false,
        # Keep container running so we can exec commands into it.
        # Without a long-running process, the container exits immediately after start.
        "Cmd" => [ "tail", "-f", "/dev/null" ]
      }
    end

    def host_config
      binds = []
      mount_mode = workspace_mount_mode
      if @workspace_volume
        binds << "#{@workspace_volume}:#{options[:workspace_mount]}:#{mount_mode}"
      elsif backend.supports_host_paths? && host_worktree_path.present?
        binds << "#{host_worktree_path}:#{options[:workspace_mount]}:#{mount_mode}"
      end

      binds << "#{heartbeat_dir_host}:#{HEARTBEAT_MOUNT_POINT}:rw" if heartbeat_dir_host

      # Mount the host's Claude config as read-only at a staging path.
      # Credentials are copied into the writable /home/agent/.claude tmpfs
      # by seed_claude_credentials! after container start.
      if backend.supports_host_paths? &&
         claude_config_host_path.present? &&
         File.directory?(claude_config_host_path) &&
         File.file?(File.join(claude_config_host_path, ".credentials.json"))
        binds << "#{claude_config_host_path}:/home/agent/.claude-host:ro"
      end

      if backend.supports_host_paths? &&
         gemini_config_host_path.present? &&
         File.directory?(gemini_config_host_path) &&
         File.file?(File.join(gemini_config_host_path, "oauth_creds.json")) &&
         gemini_subscription_auth?
        binds << "#{gemini_config_host_path}:/home/agent/.gemini-host:ro"
      end

      if backend.supports_host_paths? &&
         copilot_config_host_path.present? &&
         File.directory?(copilot_config_host_path) &&
         File.file?(File.join(copilot_config_host_path, "config.json")) &&
         copilot_subscription_auth?
        binds << "#{copilot_config_host_path}:/home/agent/.copilot-host:ro"
      end

      # /paid-heartbeat carries agent heartbeat touches used by the watchdog.
      # When the backend supports host paths we bind-mount a host temp dir so
      # both host and container can observe the same file. Backends like Swarm
      # cannot expose host paths, so keep the in-container contract intact with
      # a writable tmpfs at the same path.
      tmpfs = {}
      tmpfs[HEARTBEAT_MOUNT_POINT] = "size=#{1024 * 1024},mode=0777" unless heartbeat_dir_host

      # /tmp must be `exec` because agent containers default Bundler to
      # /tmp/bundle and the coding/review/rebase flows all run `bundle install`
      # early in execution. Bundler builds native gem extensions in
      # the gem path; mkmf's try_link verifies the produced binary with
      # File.executable?, which returns false on a noexec mount — producing
      # a misleading "compiler failed to generate an executable file" error
      # (e.g. bigdecimal extconf) even though the toolchain is fully present.
      # Docker's default tmpfs flags include noexec, so it must be overridden.
      # /home/agent/.cache needs exec because some providers (e.g. GitHub Copilot)
      # download native Node.js addons (pty.node) into ~/.cache/copilot/pkg/ at
      # runtime; dlopen() requires mmap(PROT_EXEC), which fails on a noexec mount.
      tmpfs.merge!(
        "/tmp" => "exec,size=#{options[:tmpfs_tmp_size]},mode=1777",
        "/home/agent/.cache" => "exec,size=#{options[:tmpfs_cache_size]},mode=0755"
      )

      # Claude CLI needs to write session data, project indexes, todos, debug
      # logs, and stats under ~/.claude. A writable tmpfs lets it do so without
      # compromising the read-only rootfs. Ownership is fixed by
      # fix_workspace_ownership!-style chown after container start.
      tmpfs["/home/agent/.claude"] = "size=#{256 * 1024 * 1024},mode=0700"

      # Codex CLI stores config and session data under ~/.codex.
      # Host-backed auth/config files are mounted into this tmpfs so session
      # state stays ephemeral while OAuth refreshes can still persist.
      tmpfs["/home/agent/.codex"] = "size=#{options[:tmpfs_codex_size]},mode=0700"

      # Gemini CLI stores config and session data under ~/.gemini.
      # Ownership is fixed by fix_gemini_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.gemini"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Cursor agent CLI stores config and session data under ~/.cursor-agent.
      # Ownership is fixed by fix_cursor_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.cursor-agent"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Writable directories inside the container for Kilocode CLI:
      # - ~/.kilocode (plugin data)
      # - ~/.config/kilocode (kilo.json)
      # - ~/.local/share/kilo (auth.json, kilo.db)
      # Ownership is fixed by:
      # - fix_kilocode_tmpfs_ownership! (for ~/.kilocode)
      # - fix_kilocode_config_tmpfs_ownership! (for ~/.config/kilocode)
      # - fix_kilocode_data_tmpfs_ownership! (for ~/.local/share/kilo)
      # after container start.
      tmpfs["/home/agent/.kilocode"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Kilocode CLI stores config under ~/.config/kilocode (kilo.json) and data
      # under ~/.local/share/kilo (auth.json, kilo.db).
      tmpfs["/home/agent/.config/kilocode"] = "size=#{64 * 1024 * 1024},mode=0700"
      tmpfs["/home/agent/.local/share/kilo"] = "size=#{64 * 1024 * 1024},mode=0700"

      # OpenCode CLI stores config under ~/.config/opencode and data under
      # ~/.local/share/opencode. Ownership is fixed by
      # fix_opencode_config_tmpfs_ownership! and fix_opencode_data_tmpfs_ownership!
      # after container start.
      tmpfs["/home/agent/.config/opencode"] = "size=#{64 * 1024 * 1024},mode=0700"
      tmpfs["/home/agent/.local/share/opencode"] = "size=#{64 * 1024 * 1024},mode=0700"

      # GitHub Copilot CLI stores config and auth state under ~/.copilot.
      # Ownership is fixed by fix_copilot_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.copilot"] = "size=#{64 * 1024 * 1024},mode=0700"

      {
        "Memory" => options[:memory_bytes],
        # MemorySwap == Memory disables swap. Containers exceeding the memory
        # limit are OOM-killed immediately rather than swapping to disk.
        "MemorySwap" => options[:memory_bytes],
        "CpuPeriod" => 100_000,
        "CpuQuota" => options[:cpu_quota],
        "PidsLimit" => options[:pids_limit],
        "Tmpfs" => tmpfs,
        "Binds" => binds,
        "NetworkMode" => container_network
      }
    end

    # Returns the mount mode for the workspace bind. The platform must clone
    # the repo into /workspace before enhance_issue can inspect it, so the
    # Docker mount stays writable even though the enhance prompt forbids
    # changing files and the workflow never pushes enhance_issue output.
    # @spec ISSUE-ENHANCEMENT-006
    def workspace_mount_mode
      "rw"
    end

    # Proxy-mode API key auth uses the restricted paid_agent network.
    # Subscription auth and direct-outbound runners use paid_internal so
    # runner CLIs can reach their upstream APIs directly.
    def container_network
      network_name
    end

    # Returns the Docker-specific network contract for this provision.
    #
    # When the constructor was given a +networking_policy+ (the runner-driven
    # RDR-054 path), the contract is derived from it without inspecting
    # subscription-auth or direct-outbound heuristics — those decisions are
    # already baked into the policy. Legacy direct callers fall back to
    # recomputing the contract from the current auth context.
    def network_contract
      @network_contract ||= if @networking_policy
        NetworkPolicy.contract_for_policy(@networking_policy)
      else
        NetworkPolicy.contract(
          subscription_auth: subscription_auth?,
          direct_outbound: direct_outbound_runner?
        )
      end
    end

    def direct_outbound_runner?
      return @direct_outbound_runner if instance_variable_defined?(:@direct_outbound_runner)

      @direct_outbound_runner = compute_direct_outbound_runner?
    end

    def compute_direct_outbound_runner?
      settings = resolved_user_settings
      return true if primary_runner_requires_direct_outbound?(settings)
      return false unless settings

      return true if settings.fallback_enabled? && fallback_runners_require_direct_outbound?(settings)

      rate_limit_fallback_runners_require_direct_outbound?(settings)
    end

    def primary_runner_requires_direct_outbound?(settings)
      runner_requires_direct_outbound?(primary_runner_identifier(settings), user: settings&.user)
    end

    def primary_runner_identifier(settings)
      if runnable_saved_runner?
        agent_run.runner.routing_key
      elsif agent_run&.runner.present? && settings&.fallback_enabled?
        # Saved runner exists but isn't container-executable — derive the
        # effective primary from the same fallback order that
        # RunAgentActivity#build_runner_order uses: try configured fallbacks
        # first, only fall through to the goal default when none are runnable.
        first_runnable_fallback_for_saved_runner(settings) ||
          settings.default_runner_identifier_for_goal(run_goal)
      elsif agent_run.present? && runnable_agent_type?(agent_run.agent_type)
        agent_run.agent_type
      elsif settings
        settings.default_runner_identifier_for_goal(run_goal)
      end
    end

    def runnable_saved_runner?
      agent_run&.runner.present? && runnable_runner?(agent_run.runner)
    end

    def first_runnable_fallback_for_saved_runner(settings)
      fallbacks = settings.fallback_priority_for(
        primary_runner: agent_run.runner.routing_key, identifiers: true
      )
      fallbacks.find do |identifier|
        runner = Runner.for_identifier(settings.user, identifier)
        runner && RunnerSupport.container_executable_runner_key?(runner.runner_key)
      end
    end

    def runnable_runner?(runner)
      RunnerSupport.container_executable_runner_key?(runner.runner_key)
    end

    def runnable_agent_type?(agent_type)
      return false unless agent_type.present? && AgentRun::AGENT_TYPES.include?(agent_type)

      runner_key = Runner.runner_key_for_agent_type(agent_type)
      RunnerSupport.container_executable_runner_key?(runner_key)
    end

    def run_goal
      agent_run&.goal || "create_pr"
    end

    def runner_requires_direct_outbound?(identifier, user:)
      return false if identifier.blank?
      return true if identifier.to_s == "kilocode"

      runner = Runner.for_identifier(user, identifier)
      return true if runner&.runner_key == "kilocode"

      runner&.requires_direct_outbound? || false
    end

    def fallback_runners_require_direct_outbound?(settings)
      primary_identifier = primary_runner_identifier(settings)
      fallback_identifiers = settings.fallback_priority_for(primary_runner: primary_identifier, identifiers: true)
      fallback_identifiers.any? do |identifier|
        runner_requires_direct_outbound?(identifier, user: settings.user)
      end
    end

    def rate_limit_fallback_runners_require_direct_outbound?(settings)
      rate_limit_fallback_runners = settings.user.runners.api_key.rate_limit_fallback.for_fallback
      rate_limit_fallback_runners.any?(&:requires_direct_outbound?)
    end

    def resolved_user_settings
      @resolved_user_settings ||= AgentRuns::UserSettingsResolver.call(project: project, strict: false)
    end

    def environment_variables
      proxy_base = proxy_base_url

      env = [
        "PAID_PROXY_URL=#{proxy_base}",
        "GITHUB_API_URL=#{proxy_base}/api/proxy/github",
        "KNOWLEDGE_SEARCH_URL=#{proxy_base}/api/proxy/knowledge/search",
        "PROJECT_ID=#{project.id}",
        "HOME=/home/agent",
        "BUNDLE_PATH=/tmp/bundle",
        "BUNDLE_APP_CONFIG=/tmp/bundle-config",
        "YARN_CACHE_FOLDER=/workspace/.yarn-cache"
      ]

      env.concat(run_scoped_environment(proxy_base)) if agent_run.present?
      env.concat(preview_tunnel_environment) if preview_tunnel?

      env << "PAID_COPILOT_SUBSCRIPTION_AUTH=#{copilot_subscription_auth? ? 1 : 0}"

      env << "PAID_CLAUDE_SUBSCRIPTION_AUTH=#{claude_subscription_auth? ? 1 : 0}"

      if copilot_subscription_auth? && !copilot_config_has_oauth_token?
        copilot_token = resolve_copilot_github_token
        if copilot_token.present?
          env << "COPILOT_GITHUB_TOKEN=#{copilot_token}"
          log_system("container.copilot_token_resolved")
        end
      end

      if claude_subscription_auth?
        claude_oauth_token = claude_managed_oauth_token
        env << "CLAUDE_CODE_OAUTH_TOKEN=#{claude_oauth_token}" if claude_oauth_token.present?
        # Claude subscription mode: let Claude Code use its native auth from
        # ~/.claude while other providers can still use proxy credentials.
        log_system("container.auth_mode", mode: "subscription")
      elsif agent_run.present?
        # Route Anthropic calls through the secrets proxy when Claude host auth
        # is not available, even if other providers have subscription auth.
        env.concat([
          "ANTHROPIC_BASE_URL=#{proxy_base}/api/proxy/anthropic",
          "ANTHROPIC_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
          "ANTHROPIC_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}"
        ])
      end

      # Append service container environment variables (DATABASE_URL, REDIS_URL, etc.)
      if agent_run&.service_environment.present?
        env.concat(agent_run.service_environment.map { |k, v| "#{k}=#{v}" })
      end

      # Set git committer identity globally via environment variables.
      # This ensures git operations (rebase, commit, cherry-pick) never fail
      # with "Committer identity unknown" regardless of local .git/config state.
      git_identity = Github::BotIdentity.for_git
      env.concat([
        "GIT_AUTHOR_NAME=#{git_identity.name}",
        "GIT_AUTHOR_EMAIL=#{git_identity.email}",
        "GIT_COMMITTER_NAME=#{git_identity.name}",
        "GIT_COMMITTER_EMAIL=#{git_identity.email}"
      ])

      env
    end

    def run_scoped_environment(proxy_base)
      env = [
        "AGENT_RUN_ID=#{agent_run.id}",
        "PROXY_TOKEN=#{agent_run.proxy_token}",
        "OPENAI_BASE_URL=#{proxy_base}/api/proxy/openai",
        "OPENAI_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
        "OPENAI_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
        "OPENAI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}",
        "PAID_CODEX_SUBSCRIPTION_AUTH=#{codex_subscription_auth? ? 1 : 0}",
        "GOOGLE_GEMINI_BASE_URL=#{proxy_base}/api/proxy/google",
        "GOOGLE_GENAI_BASE_URL=#{proxy_base}/api/proxy/google",
        "GOOGLE_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
        "GOOGLE_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
        "GEMINI_CLI_CUSTOM_HEADERS=X-Agent-Run-Id: #{agent_run.id}, X-Proxy-Token: #{agent_run.proxy_token}",
        "GEMINI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}",
        "PAID_GEMINI_SUBSCRIPTION_AUTH=#{gemini_subscription_auth? ? 1 : 0}"
      ]

      # Append runner-specific CLI settings (e.g. sandbox flags, retry config)
      # from agent-harness so the gem is the single source of truth.
      # Filter out vars already set above so app-managed values (e.g.
      # PAID_CODEX_SUBSCRIPTION_AUTH) are never overridden by harness defaults.
      existing_keys = env.each_with_object(Set.new) { |entry, set| set << entry.split("=", 2).first }
      env.concat(runner_cli_env_overrides.reject { |entry| existing_keys.include?(entry.split("=", 2).first) })

      env
    end

    # Intentionally no rescue — if a harness runner is misconfigured or
    # stops exporting cli_env_overrides, we want the error to propagate so
    # containers are never provisioned without required flags (e.g.
    # GEMINI_SANDBOX=false).
    def runner_cli_env_overrides
      RunnerSupport::CONTAINER_EXECUTABLE_RUNNER_KEYS.flat_map do |key|
        harness_key = RunnerSupport.harness_runner_key_for(key).to_sym
        AgentHarness.provider(harness_key).cli_env_overrides.map { |k, v| "#{k}=#{v}" }
      end
    end

    def exec_environment(env)
      values = environment_variables.to_h { |value| value.split("=", 2) }
      values.merge!(env.transform_keys(&:to_s))
      values.map { |key, value| "#{key}=#{value}" }
    end

    def pooled_container?
      pool_entry.present?
    end

    # Returns true when any runner CLI config is available for
    # subscription-based authentication via copied host login state.
    def subscription_auth?
      claude_subscription_auth? || codex_subscription_auth? || gemini_subscription_auth? || copilot_subscription_auth?
    end

    def proxy_base_url
      if @networking_policy
        Containers::ProxyUrl.resolve(backend:, policy: @networking_policy)
      else
        Containers::ProxyUrl.resolve(backend:, restricted: network_contract.restricted?)
      end
    end

    # Enforces the RDR-041/RDR-048 subscription auth host eligibility contract
    # (#2963) before provisioning. On backends that cannot mount host paths
    # (remote Docker, Swarm), host-forwarded subscription auth is rejected with a
    # named reason, while managed remote-safe credentials (e.g. Claude OAuth
    # stored as a RunnerCredential) remain eligible because they materialize
    # inside the container without a bind mount.
    #
    # record_telemetry controls whether RunnerAuthAttempt rows are written.
    # Pass record_telemetry: false when checking compatibility speculatively
    # (e.g. during queue scheduling) to avoid N × DB-write + filesystem-probe
    # overhead per queue pass. The provision path always records telemetry.
    def validate_backend_mount_support!(record_telemetry: true)
      return if backend.supports_host_paths?

      rejections = []
      rejections << worktree_mount_rejection if host_worktree_path.present?
      rejections.concat(subscription_auth_mount_rejections)
      record_eligibility_attempts! if record_telemetry
      return if rejections.empty?

      raise ProvisionError, format_backend_mount_rejections(rejections)
    end

    def worktree_mount_rejection
      {
        reason: :requires_host_bind_mount,
        runner_key: nil,
        message: "worktree path #{host_worktree_path} requires a host bind mount"
      }
    end

    # Evaluates each detected host-forwarded subscription auth source against the
    # backend via Runners::SubscriptionAuthEligibility. Providers whose run is
    # carried by a managed remote-safe credential are skipped (eligible); the
    # rest surface a named rejection reason safe for the queue/readiness UI.
    def subscription_auth_mount_rejections
      subscription_auth_host_sources.filter_map do |entry|
        runner_key = entry.fetch(:runner_key)
        next if managed_remote_safe_for?(runner_key)

        auth_source = Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: :host_forwarded
        )
        result = Runners::SubscriptionAuthEligibility.call(
          backend: backend,
          auth_source: auth_source,
          proxy_reachable: backend_proxy_reachable?
        )
        next if result.eligible?

        {
          reason: result.reason,
          runner_key: runner_key,
          host_path: entry[:host_path],
          message: result.message
        }
      end
    end

    def subscription_auth_host_sources
      @subscription_auth_host_sources ||= [
        { runner_key: "claude",
          host_path: claude_config_host_path,
          detected: host_only_auth_source?(claude_config_host_path, ".credentials.json", claude_local_config_path) },
        { runner_key: "codex",
          host_path: codex_subscription_auth_host_mount_path,
          detected: codex_subscription_auth_host_mount_path.present? },
        { runner_key: "gemini",
          host_path: gemini_config_host_path,
          detected: host_only_auth_source?(gemini_config_host_path, "oauth_creds.json", gemini_local_config_path) },
        { runner_key: "copilot",
          host_path: copilot_config_host_path,
          detected: host_only_auth_source?(copilot_config_host_path, "config.json", copilot_local_config_path) }
      ].select { |entry| entry[:detected] }
    end

    # RDR-041 / #2960 — record a runner auth attempt for each detected
    # subscription auth source on the resolved backend. Captures the
    # auth_source, materialization_mode, container_host, feature-flag state,
    # and the eligibility outcome so managed-vs-host comparisons can slice by
    # provider and Docker host.
    def record_eligibility_attempts!
      return unless project.is_a?(Project)

      subscription_auth_host_sources.each do |entry|
        runner_key = entry.fetch(:runner_key)
        # Resolve the latest credential regardless of status so an expired or
        # revoked managed credential still surfaces as `:managed` with
        # credential_state `:expired`/`:revoked`, letting the eligibility
        # service return `credential_expired` instead of silently falling back
        # to `host_forwarded` (or `managed_auth_missing`).
        credential = managed_subscription_credential_for(runner_key, require_active: false)
        auth_source = if credential && managed_subscription_materializable_for?(runner_key, credential: credential)
          Runners::SubscriptionAuthEligibility::AuthSource.new(
            runner_key: runner_key,
            auth_mode: :managed,
            credential_state: credential.expired? ? :expired : credential.revoked? ? :revoked : :active
          )
        else
          Runners::SubscriptionAuthEligibility::AuthSource.new(
            runner_key: runner_key,
            auth_mode: :host_forwarded
          )
        end
        eligibility = Runners::SubscriptionAuthEligibility.call(
          backend: backend,
          auth_source: auth_source,
          proxy_reachable: backend_proxy_reachable?
        )

        # The materializer registry documents the *managed* shape per provider;
        # for host_forwarded attempts the actual seeding path always uses a
        # host bind mount regardless of provider, so tag the row with the mode
        # the seeding path will use. Otherwise a host_forwarded Claude row would
        # be tagged with the managed materializer's env/native_file mode,
        # corrupting the managed-vs-host comparison this telemetry exists to
        # produce.
        materialization_mode = if auth_source.auth_mode == :managed
          Runners::SubscriptionAuthMaterializers.for_runner(runner_key)&.materialization_mode
        else
          Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT
        end
        result = eligibility.eligible? ? RunnerAuthAttempt::RESULT_MATERIALIZED : RunnerAuthAttempt::RESULT_FAILED

        record_auth_attempt!(
          runner_key: runner_key,
          attempt_stage: RunnerAuthAttempt::STAGE_ELIGIBILITY,
          auth_source: auth_source,
          materialization_mode: materialization_mode,
          runner_credential: credential,
          result: result,
          failure_reason: eligibility.reason
        )
      end
    end

    # True when a managed RunnerCredential with a remote-safe materializer
    # carries this provider's subscription auth, so the run does not need a host
    # bind mount. Today only Claude has a remote-safe managed materializer.
    def managed_remote_safe_for?(runner_key)
      return false unless Runners::SubscriptionAuthMaterializers.remote_safe?(runner_key)

      credential = managed_subscription_credential_for(runner_key)
      credential&.active? && managed_subscription_materializable_for?(runner_key, credential: credential)
    end

    # @param require_active [Boolean] When true (default), only returns active
    #   credentials. When false, returns the latest credential regardless of
    #   status so callers can distinguish `credential_expired` from
    #   `managed_auth_missing` in telemetry.
    def managed_subscription_credential_for(runner_key, require_active: true)
      scope = managed_subscription_credential_scope_for(runner_key)
      return nil unless scope

      scope = scope.active if require_active
      scope.order(created_at: :desc, id: :desc).first
    end

    # @spec EXECUTION-ISOLATION-003
    def managed_subscription_credential_scope_for(runner_key)
      return nil unless project.is_a?(Project)

      account = project.account
      return nil unless account

      scope = account.runner_credentials.for_runner(runner_key)
      return scope.where(auth_kind: "oauth_token") if %w[claude codex gemini copilot].include?(runner_key.to_s)

      scope
    end

    def managed_subscription_runner_auth_enabled?
      project.is_a?(Project) && FeatureFlags.enabled?(:managed_subscription_runner_auth, project: project)
    end

    def managed_subscription_materializable_for?(runner_key, credential: nil)
      return false unless managed_subscription_runner_auth_enabled_for?(runner_key)

      provider = subscription_auth_provider_for(runner_key)
      secret = credential&.token.to_s.presence ||
        managed_subscription_credential_for(runner_key, require_active: false)&.token.to_s.presence
      if provider && secret.present?
        status = provider.status(secret: secret)
        # Eligibility classification tracks credential *presence*, not
        # materializability: an expired/non-refreshable managed credential
        # must still surface as `:managed` with credential_state `:expired` so
        # `record_eligibility_attempts!` reports `credential_expired` instead
        # of silently falling back to `host_forwarded`. All four subscription
        # providers (Claude, Codex, Gemini, Copilot) now have concrete adapters,
        # so a non-unsupported status is authoritative.
        return status.present? unless status.unsupported?
      end

      false
    end

    def managed_subscription_runner_auth_enabled_for?(runner_key)
      return true unless %w[gemini copilot].include?(runner_key.to_s)

      managed_subscription_runner_auth_enabled?
    end

    # Whether the backend's Paid proxy callback is reachable for API-key/proxy
    # auth. Remote backends require PAID_PROXY_EXTERNAL_URL; if it is missing or
    # malformed, proxy auth is not eligible. Local backends always reach the
    # in-process proxy.
    def backend_proxy_reachable?
      return true unless backend.respond_to?(:remote?)
      return true unless backend.remote?

      Containers::ProxyUrl.resolve(backend:, restricted: true).present?
    rescue StandardError
      false
    end

    def format_backend_mount_rejections(rejections)
      details = rejections.map do |rejection|
        label = rejection[:runner_key].present? ? "#{rejection[:runner_key].capitalize} subscription auth" : "workspace"
        "#{label} (#{rejection.fetch(:reason)}): #{rejection.fetch(:message)}"
      end
      "Backend #{backend.identifier} cannot host this run: #{details.join('; ')}. " \
        "Use a host-path-capable backend or configure managed subscription credentials."
    end

    def host_only_auth_source?(host_path, marker_file, local_path)
      return false unless host_path.present? && File.file?(File.join(host_path, marker_file))

      local_path.blank? || !File.file?(File.join(local_path, marker_file))
    end

    # Returns the Docker-host path to the Claude config directory.
    # Checks CLAUDE_CONFIG_DIR first, then auto-detects from container mounts
    # (for DooD setups where the devcontainer mounts ~/.claude from the host).
    def claude_config_host_path
      @claude_config_host_path ||= ENV["CLAUDE_CONFIG_DIR"].presence || detect_host_config_path("/.claude")
    end

    def claude_local_config_path
      @claude_local_config_path ||=
        local_config_path(".claude") || local_config_path(".config/claude")
    end

    def gemini_config_host_path
      @gemini_config_host_path ||= ENV["GEMINI_CONFIG_DIR"].presence || detect_host_config_path("/.gemini")
    end

    def gemini_local_config_path
      @gemini_local_config_path ||= local_config_path(".gemini")
    end

    def codex_config_host_path
      codex_subscription_auth_host_mount_path
    end

    def codex_config_candidate_paths
      [ ENV["CODEX_CONFIG_DIR"].presence, ENV["CODEX_HOME"].presence ].compact
    end

    def codex_local_config_path
      @codex_local_config_path ||= local_config_path(".codex")
    end

    def claude_subscription_auth?
      return true if claude_managed_secret && !claude_managed_secret.blank?

      paths = [ claude_config_host_path, claude_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, ".credentials.json")) }
    end

    def claude_managed_oauth_token
      materialization = claude_managed_materialization
      return unless materialization&.supported?

      materialization.env["CLAUDE_CODE_OAUTH_TOKEN"].to_s.presence
    end

    def claude_managed_runner_credential
      return @claude_managed_runner_credential if defined?(@claude_managed_runner_credential)

      @claude_managed_runner_credential = managed_subscription_credential_scope_for("claude")&.active
        &.order(created_at: :desc, id: :desc)&.first
    end

    def claude_managed_secret
      return @claude_managed_secret if defined?(@claude_managed_secret)

      secret = claude_managed_runner_credential&.token.to_s
      @claude_managed_secret = secret.present? ? ClaudeCredentials::Secret.parse(secret) : nil
    end

    def claude_managed_materialization
      return @claude_managed_materialization if defined?(@claude_managed_materialization)

      secret = claude_managed_runner_credential&.token.to_s
      @claude_managed_materialization =
        if secret.present?
          claude_subscription_auth_provider.materialize(secret: secret)
        end
    end

    def materialize_managed_claude_credentials!
      materialization = claude_managed_materialization
      return false unless materialization&.supported?

      materialization.files.each do |path, content|
        write_container_file(path, content)
      end

      source = if materialization.mode == Runners::SubscriptionAuthMaterializers::MATERIALIZE_ENV
        "managed_env_token"
      else
        "managed_json"
      end

      log_system("container.claude_credentials_seeded",
        source: source,
        auth_source: RunnerAuthAttempt::AUTH_SOURCE_MANAGED)
      record_auth_attempt!(
        runner_key: "claude",
        attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
        auth_source: :managed,
        materialization_mode: materialization.mode,
        runner_credential: claude_managed_runner_credential,
        result: RunnerAuthAttempt::RESULT_MATERIALIZED,
        metadata: materialization.redacted_metadata.merge("source" => source)
      )
      true
    end

    # Materializes the managed Codex `auth.json` directly into the container from
    # the canonical encrypted `RunnerCredential` (RDR-041 / #2962). No host bind
    # mount is required, so the run can authenticate on any backend once remote
    # placement is enabled. Before materializing, performs a refresh-before-run
    # under a per-credential lease so the rotated access token — not a stale one
    # — is what the Codex CLI reads.
    def materialize_managed_codex_credentials!
      credential = codex_managed_runner_credential
      return false unless credential

      refresh_codex_managed_credential!(provision: true)

      # Re-resolve materialization after a refresh may have rotated the token.
      reset_codex_managed_caches
      materialization = codex_managed_materialization
      return false unless materialization&.supported?

      materialization.files.each do |path, content|
        write_container_file(path, content)
      end
      credential.update_column(:last_used_at, Time.current)

      log_system("container.codex_credentials_seeded", source: "managed_json")
      record_auth_attempt!(
        runner_key: "codex",
        attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
        auth_source: :managed,
        materialization_mode: materialization.mode,
        runner_credential: credential,
        result: RunnerAuthAttempt::RESULT_MATERIALIZED,
        metadata: materialization.redacted_metadata.merge("source" => "managed_json")
      )
      true
    end

    def gemini_subscription_auth?
      if managed_subscription_runner_auth_enabled_for?("gemini")
        return true if gemini_managed_secret && !gemini_managed_secret.blank?
      end

      paths = [ gemini_config_host_path, gemini_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, "oauth_creds.json")) }
    end

    def gemini_managed_oauth_creds_json
      parsed = gemini_managed_secret
      return unless parsed&.oauth_credentials?

      parsed.oauth_creds_json
    end

    def gemini_managed_runner_credential
      return @gemini_managed_runner_credential if defined?(@gemini_managed_runner_credential)

      @gemini_managed_runner_credential = managed_subscription_credential_scope_for("gemini")&.active
        &.order(created_at: :desc, id: :desc)&.first
    end

    def gemini_managed_secret
      return @gemini_managed_secret if defined?(@gemini_managed_secret)

      secret = gemini_managed_runner_credential&.token.to_s
      @gemini_managed_secret = secret.present? ? GeminiCredentials::Secret.parse(secret) : nil
    end

    def codex_subscription_auth?
      return true if codex_managed_credential_active?

      codex_subscription_auth_mount.present?
    end

    def codex_managed_credential_active?
      codex_managed_runner_credential.present? && codex_managed_materializable?
    end

    def codex_managed_materializable?
      materialization = codex_managed_materialization
      materialization&.supported?
    end

    def codex_managed_runner_credential
      return @codex_managed_runner_credential if defined?(@codex_managed_runner_credential)

      @codex_managed_runner_credential = managed_subscription_credential_scope_for("codex")&.active
        &.order(created_at: :desc, id: :desc)&.first
    end

    def codex_managed_secret
      return @codex_managed_secret if defined?(@codex_managed_secret)

      secret = codex_managed_runner_credential&.token.to_s
      @codex_managed_secret = secret.present? ? CodexCredentials::Secret.parse(secret) : nil
    end

    def codex_managed_materialization
      return @codex_managed_materialization if defined?(@codex_managed_materialization)

      secret = codex_managed_runner_credential&.token.to_s
      @codex_managed_materialization =
        if secret.present?
          codex_subscription_auth_provider.materialize(secret: secret)
        end
    end

    def codex_subscription_auth_provider
      @codex_subscription_auth_provider ||= Runners::SubscriptionAuthProviders.for_runner("codex")
    end

    # Clears the memoized managed Codex caches so a refresh/rotation is picked up
    # on the next read. Required because the memo guards use `defined?`, which
    # stays truthy after an explicit `= nil` assignment. The cached credential
    # itself must also be dropped because `codex_managed_secret` and
    # `codex_managed_materialization` derive from `credential.token`; an in-memory
    # AR object that survived `with_lock` could still hold the pre-refresh token
    # until a reload, leaving the re-derived caches stale (#2990 review).
    def reset_codex_managed_caches
      remove_instance_variable(:@codex_managed_runner_credential) if defined?(@codex_managed_runner_credential)
      remove_instance_variable(:@codex_managed_secret) if defined?(@codex_managed_secret)
      remove_instance_variable(:@codex_managed_materialization) if defined?(@codex_managed_materialization)
    end

    def unshared_codex_subscription_auth?
      unshared_codex_auth_path.present? && codex_subscription_runner_requested?
    end

    def unshared_codex_auth_path
      codex_readable_config_paths.find do |path|
        File.file?(File.join(path, "auth.json")) && docker_host_path_for(path).blank?
      end
    end

    def codex_subscription_runner_requested?
      return false unless agent_run

      runners = resolved_run_runner_candidates
      return runners.any? { |runner| runner.runner_key == "codex" && runner.subscription? } if runners.any?

      RunnerSupport.runner_key_for_agent_type(agent_run.agent_type) == "codex"
    end

    # Memoized: several provision-time guards (opencode/kilo/codex runner
    # detection) resolve the candidate chain, and it is deterministic for a
    # given run + settings. Caching avoids repeated Runner.for_identifier
    # lookups on the provision path.
    def resolved_run_runner_candidates
      return @resolved_run_runner_candidates if defined?(@resolved_run_runner_candidates)

      @resolved_run_runner_candidates = compute_resolved_run_runner_candidates
    end

    def compute_resolved_run_runner_candidates
      return run_runner_candidates if agent_run.runner

      settings = resolved_user_settings
      return [] unless settings

      primary = settings.default_runner_identifier_for_goal(agent_run.goal)
      identifiers = [ primary ].compact
      if settings.fallback_enabled?
        identifiers.concat(settings.fallback_priority_for(primary_runner: primary, identifiers: true))
      end

      runners_for_identifiers(identifiers, user: settings.user)
    end

    def run_runner_candidates
      runners = [ agent_run.runner ]
      settings = resolved_user_settings
      if settings&.fallback_enabled?
        runners.concat(runners_for_identifiers(
          settings.fallback_priority_for(primary_runner: agent_run.runner.routing_key, identifiers: true),
          user: settings.user
        ))
      end

      runners.compact
    end

    def runners_for_identifiers(identifiers, user:)
      identifiers.filter_map do |identifier|
        Runner.for_identifier(user, identifier)
      end
    end

    def raise_unshared_codex_auth_error!
      raise ProvisionError,
        "Codex subscription auth was found at #{unshared_codex_auth_path}, but that directory is not available as a Docker bind mount. " \
        "Set CODEX_HOME or CODEX_CONFIG_DIR to a writable Docker-host path containing auth.json."
    end

    def codex_subscription_auth_host_mount_path
      codex_subscription_auth_mount&.host_path
    end

    def codex_subscription_auth_mount
      return @codex_subscription_auth_mount if defined?(@codex_subscription_auth_mount)

      @codex_subscription_auth_mount = codex_subscription_auth_mount_candidates.find do |mount|
        mount.host_path.present? &&
          mount.config_path.present? &&
          File.file?(File.join(mount.config_path, "auth.json"))
      end
    end

    def codex_subscription_auth_mount_candidates
      codex_readable_config_paths.map do |path|
        CodexAuthMount.new(host_path: docker_host_path_for(path), config_path: path)
      end + [ detected_codex_auth_mount ].compact
    end

    def codex_readable_config_paths
      (codex_config_candidate_paths + [ codex_local_config_path ]).compact.uniq
    end

    def codex_auth_lock_required?(command)
      codex_subscription_auth? && codex_exec_command?(command)
    end

    def codex_exec_command?(command)
      parts = normalized_command_parts(command)
      return false if parts.empty?

      if parts.first == "env"
        index = 1
        while index < parts.length
          case parts[index]
          when "-u"
            index += 2
          else
            break
          end
        end
        parts = parts[index..] || []
      end

      return true if parts[0] == "sh" && parts[1] == "-c" && parts[2]&.match?(/\bcodex\s+exec\b/)

      parts.first(2) == %w[codex exec]
    rescue ArgumentError
      false
    end

    def normalized_command_parts(command)
      command.is_a?(Array) ? command.map(&:to_s) : Shellwords.split(command.to_s)
    end

    def codex_auth_lockfile_path
      runner = codex_harness_provider
      lock_config = runner.respond_to?(:auth_lock_config) ? runner.auth_lock_config : nil
      base_path = lock_config&.dig(:path)&.sub(/\.lock\z/, "")
      raise TypeError, "no lock path configured" unless base_path

      source_path = codex_subscription_auth_source_path
      digest = Digest::SHA256.hexdigest(source_path)[0, 16]
      "#{base_path}-#{digest}.lock"
    rescue TypeError
      base = lock_config&.dig(:path)&.sub(/\.lock\z/, "") || "/tmp/codex-auth"
      "#{base}-missing.lock"
    end

    def codex_subscription_auth_source_path
      codex_subscription_auth_mount&.config_path
    end

    def sync_codex_auth_file_to_source!
      source_path = codex_subscription_auth_source_path
      return if source_path.blank?

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      source_file = File.join(source_path, "auth.json")
      stdout, stderr, status = backend.exec_in_container(
        container,
        [ "sh", "-lc", "base64 -w0 /home/agent/.codex/auth.json" ],
        user: "agent"
      )
      raise Docker::Error::DockerError, Array(stderr).join if status.to_i != 0

      encoded = Array(stdout).join
      if encoded.blank?
        record_auth_attempt!(
          runner_key: "codex",
          attempt_stage: RunnerAuthAttempt::STAGE_HARVEST,
          auth_source: :host_forwarded,
          materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
          result: RunnerAuthAttempt::RESULT_SKIPPED,
          failure_reason: "no_rotated_credential",
          metadata: { source: "host_mount" }
        )
        return
      end

      File.binwrite(source_file, Base64.strict_decode64(encoded))
      log_system("container.codex_auth_synced", source_path: source_path)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      record_auth_attempt!(
        runner_key: "codex",
        attempt_stage: RunnerAuthAttempt::STAGE_HARVEST,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        result: RunnerAuthAttempt::RESULT_HARVESTED,
        duration_ms: duration_ms,
        metadata: { source: "host_mount" }
      )
    rescue Docker::Error::DockerError, SystemCallError, ArgumentError => e
      # The full exception text (which routinely contains absolute host paths,
      # container IDs, and other host-fingerprint data) is captured in the
      # agent-run log via log_system below; keep the telemetry row free of it.
      log_system("container.codex_auth_sync_failed", error: e.message, source_path: source_path)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      record_auth_attempt!(
        runner_key: "codex",
        attempt_stage: RunnerAuthAttempt::STAGE_HARVEST,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        result: RunnerAuthAttempt::RESULT_HARVEST_FAILED,
        failure_reason: "exec_failed",
        duration_ms: duration_ms,
        metadata: { source: "host_mount" }
      )
    end

    def codex_harness_provider
      AgentHarness.provider(:codex)
    end

    # Deterministic, per-credential lockfile for the managed Codex lease. Keyed
    # on the RunnerCredential id so runs sharing a credential serialize while
    # independent credentials stay fully parallel. Mirrors the host-path
    # codex_auth_lockfile_path shape for the managed path.
    CODEX_MANAGED_AUTH_LOCK_BASE_PATH = "/tmp/codex-managed-auth"

    def codex_managed_auth_lockfile_path
      credential_id = codex_managed_runner_credential&.id
      return "#{CODEX_MANAGED_AUTH_LOCK_BASE_PATH}-missing.lock" unless credential_id

      digest = Digest::SHA256.hexdigest("codex-managed:#{credential_id}")[0, 16]
      "#{CODEX_MANAGED_AUTH_LOCK_BASE_PATH}-#{digest}.lock"
    end

    # Public boundary for the Codex managed refresh (RDR-041 / #2962). Refreshes
    # the canonical RunnerCredential under a per-credential lease when the access
    # token is near expiry. Returns truthy when a refresh ran, nil otherwise.
    #
    # When `provision:` is true, the refresh is forced ahead of materialization
    # even when a near-expiry refresh already ran this tick, so the materialized
    # auth.json always reflects the freshest server-side state.
    def refresh_codex_managed_credential_if_needed!(provision: false)
      credential = codex_managed_runner_credential
      return nil unless credential

      refresh_codex_managed_credential_with_lease!(credential, provision: provision)
    end

    CODEX_CREDENTIAL_REFRESH_WINDOW = 10 * 60 # 10 minutes

    def refresh_codex_managed_credential_with_lease!(credential, provision: false)
      return nil unless codex_managed_credential_near_expiry?(credential)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      refresh_state = RunnerAuthAttempt::REFRESH_NOT_NEEDED

      with_codex_managed_refresh_lease(credential) do
        # Re-check after acquiring the lock: another Paid instance may have
        # already refreshed this credential while we waited. When called from
        # materialize_managed_codex_credentials! (provision: true) we bypass
        # this re-check so the materialized auth.json always reflects the token
        # that was current when we entered the near-expiry window, not a stale
        # read from another concurrent refresh attempt.
        unless provision || codex_managed_credential_near_expiry?(credential.reload)
          record_codex_refresh_attempt!(credential, started_at,
            refresh_state: RunnerAuthAttempt::REFRESH_NOT_NEEDED,
            result: RunnerAuthAttempt::RESULT_SKIPPED,
            failure_reason: "already_refreshed")
          return nil
        end

        outcome = exchange_codex_refresh_token!(credential)
        refresh_state = outcome ? RunnerAuthAttempt::REFRESH_REFRESHED : RunnerAuthAttempt::REFRESH_REFRESH_FAILED
        record_codex_refresh_attempt!(credential, started_at,
          refresh_state: refresh_state,
          result: outcome ? RunnerAuthAttempt::RESULT_REFRESHED : RunnerAuthAttempt::RESULT_REFRESH_FAILED,
          failure_reason: outcome ? nil : "exchange_refresh_token_unsupported")
        outcome
      end
    end

    def codex_managed_credential_near_expiry?(credential = codex_managed_runner_credential)
      return false unless credential

      expiry = credential.expires_at
      expiry = codex_managed_secret&.expires_at if expiry.nil?
      return false if expiry.nil?

      expiry <= (Time.now + CODEX_CREDENTIAL_REFRESH_WINDOW)
    end

    # Serializes concurrent refresh attempts on the same managed credential.
    # Uses the RunnerCredential row lock so refresh is safe across hosts once
    # remote placement is enabled; pairs with the file-based exec lease.
    def with_codex_managed_refresh_lease(credential)
      credential.with_lock { yield }
    end

    # Performs the actual Codex refresh-token exchange and writes the rotated
    # auth.json back into the canonical RunnerCredential. Delegates to
    # `AgentHarness::Authentication.exchange_refresh_token` when the upstream
    # Codex exchange is supported (viamin/agent-harness#265); until then logs
    # unsupported and returns false so the lease and telemetry stay wired while
    # the harvest path remains the source of rotated state.
    def exchange_codex_refresh_token!(credential)
      unless codex_refresh_exchange_supported?
        log_system("container.codex_auth_refresh.unsupported",
          note: "agent-harness codex refresh not yet available; skipping server-side exchange")
        return false
      end

      refreshed = AgentHarness::Authentication.exchange_refresh_token(:codex)
      apply_codex_refresh_result!(credential, refreshed.to_h)
      log_system("container.codex_auth_refreshed", credential_id: credential.id)
      true
    rescue AgentHarness::AuthenticationError => e
      log_system("container.codex_auth_refresh_failed",
        error: e.message,
        credential_id: credential.id,
        note: "classify as auth_expired via refresh_token_reused pattern if applicable")
      false
    rescue InvalidCodexRefreshResponse => e
      # Refresh returned a non-Codex payload (or one without an access token).
      # The canonical credential is left untouched; classify as a failed refresh
      # rather than persisting an unusable token (#2962 review).
      log_system("container.codex_auth_refresh_failed",
        error: e.message,
        credential_id: credential.id,
        note: "refresh response rejected: #{e.reason || 'unusable'}; credential unchanged")
      false
    rescue AgentHarness::Error, JSON::ParserError, SystemCallError => e
      log_system("container.codex_auth_refresh_failed", error: e.message, credential_id: credential.id)
      false
    end

    def codex_refresh_exchange_supported?
      AgentHarness::Authentication.respond_to?(:exchange_refresh_token) &&
        AgentHarness::Authentication.respond_to?(:exchange_refresh_token_supported?) &&
        AgentHarness::Authentication.exchange_refresh_token_supported?(:codex)
    end

    def apply_codex_refresh_result!(credential, refreshed_payload)
      token = refreshed_payload.is_a?(Hash) ? refreshed_payload.dig(:token) || JSON.generate(refreshed_payload) : refreshed_payload.to_s
      parsed = CodexCredentials::Secret.parse(token.to_s)
      # A successful refresh must yield a usable Codex auth.json (an access
      # token). Reject blank/non-Codex payloads or refresh-token-only responses
      # before touching the canonical credential, otherwise an unexpected
      # upstream exchange overwrites the stored token with garbage (#2962 review).
      unless valid_codex_refresh_response?(parsed)
        raise InvalidCodexRefreshResponse.new(
          "Codex refresh response is not a usable auth.json",
          reason: parsed.codex_auth? ? "missing_access_token" : "not_codex_auth"
        )
      end

      credential.assign_attributes(
        token: token.to_s,
        expires_at: parsed.expires_at || credential.expires_at,
        revoked_at: nil,
        metadata: credential.metadata.to_h.merge(
          "source" => "server_refresh",
          "storage_format" => "codex_auth_json",
          "access_token_expires_at" => (parsed.expires_at || credential.expires_at)&.iso8601
        ).compact
      )
      credential.save!
    end

    def valid_codex_refresh_response?(parsed)
      parsed.codex_auth? && parsed.access_token.present?
    end

    def record_codex_refresh_attempt!(credential, started_at, refresh_state:, result:, failure_reason: nil)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      record_auth_attempt!(
        runner_key: "codex",
        attempt_stage: RunnerAuthAttempt::STAGE_REFRESH,
        auth_source: :managed,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
        runner_credential: credential,
        refresh_state: refresh_state,
        result: result,
        failure_reason: failure_reason,
        duration_ms: duration_ms,
        metadata: { source: "managed" }
      )
    end

    # Harvests the rotated `/home/agent/.codex/auth.json` from the container back
    # into the canonical managed RunnerCredential after a run (RDR-041 / #2962).
    # The Codex CLI may rotate auth.json in-container, so without this writeback
    # the canonical credential would go stale after the first successful run.
    # Returns the provider Result contract so the adapter can report harvest state.
    def harvest_codex_managed_credential_impl!
      credential = codex_managed_runner_credential
      return unsupported_codex_harvest_result unless credential

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = backend.exec_in_container(
        container,
        [ "sh", "-lc", "base64 -w0 /home/agent/.codex/auth.json" ],
        user: "agent"
      )
      raise Docker::Error::DockerError, Array(stderr).join if status.to_i != 0

      encoded = Array(stdout).join
      if encoded.blank?
        record_codex_harvest_attempt!(credential, started_at,
          result: RunnerAuthAttempt::RESULT_SKIPPED, failure_reason: "no_rotated_credential")
        return codex_harvest_result(performed: false, reason: "no_rotated_credential")
      end

      rotated = Base64.strict_decode64(encoded)
      parsed = CodexCredentials::Secret.parse(rotated)
      unless parsed.codex_auth?
        record_codex_harvest_attempt!(credential, started_at,
          result: RunnerAuthAttempt::RESULT_HARVEST_FAILED, failure_reason: "malformed_rotated_credential")
        return codex_harvest_result(performed: false, reason: "malformed_rotated_credential")
      end

      # CodexCredentials::Secret treats a refresh-token-only payload as a valid
      # Codex auth, but a rotation without an access token is not harvestable:
      # persisting it would brick the next materialization (no token for the CLI,
      # and a nil expiry skips the pre-run refresh). Treat it as a harvest
      # failure so telemetry matches what was actually persisted (#2962 review).
      unless parsed.access_token.present?
        record_codex_harvest_attempt!(credential, started_at,
          result: RunnerAuthAttempt::RESULT_HARVEST_FAILED, failure_reason: "rotated_credential_missing_access_token")
        return codex_harvest_result(performed: false, reason: "rotated_credential_missing_access_token")
      end

      update_codex_managed_credential_from_rotation!(credential, rotated, parsed)
      reset_codex_managed_caches
      log_system("container.codex_managed_auth_harvested", credential_id: credential.id)
      record_codex_harvest_attempt!(credential, started_at, result: RunnerAuthAttempt::RESULT_HARVESTED)
      codex_harvest_result(performed: true, reason: "harvested")
    rescue Docker::Error::DockerError, SystemCallError, ArgumentError => e
      log_system("container.codex_managed_auth_harvest_failed",
        error: e.message, credential_id: credential&.id)
      record_codex_harvest_attempt!(credential, started_at,
        result: RunnerAuthAttempt::RESULT_HARVEST_FAILED, failure_reason: "exec_failed")
      codex_harvest_result(performed: false, reason: "harvest_failed")
    end

    # Persists the harvested rotation. The caller (harvest_codex_managed_credential_impl!)
    # validates that `parsed` is a Codex auth carrying an access token before
    # reaching here, so this method applies directly rather than silently no-op'ing
    # on an unusable payload (#2962 review).
    def update_codex_managed_credential_from_rotation!(credential, rotated_auth_json, parsed)
      credential.assign_attributes(
        token: rotated_auth_json,
        expires_at: parsed.expires_at || credential.expires_at,
        last_used_at: Time.current,
        revoked_at: nil,
        metadata: credential.metadata.to_h.merge(
          "source" => "container_rotation_harvest",
          "storage_format" => "codex_auth_json",
          "access_token_expires_at" => (parsed.expires_at || credential.expires_at)&.iso8601
        ).compact
      )
      credential.save!
    end

    def record_codex_harvest_attempt!(credential, started_at, result:, failure_reason: nil)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      record_auth_attempt!(
        runner_key: "codex",
        attempt_stage: RunnerAuthAttempt::STAGE_HARVEST,
        auth_source: :managed,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE,
        runner_credential: credential,
        result: result,
        failure_reason: failure_reason,
        duration_ms: duration_ms,
        metadata: { source: "managed" }
      )
    end

    def codex_harvest_result(performed:, reason:)
      Runners::SubscriptionAuthProviders::Result.new(supported: true, performed: performed, reason: reason)
    end

    def unsupported_codex_harvest_result
      Runners::SubscriptionAuthProviders::Result.new(supported: false, performed: false, reason: "no_managed_credential")
    end

    # Phase 3 — Claude credential keep-warm (RDR-041).
    #
    # Mirrors the Codex with_codex_auth_lock pattern for the host-forwarded
    # Claude `.credentials.json`. The Claude CLI does not auto-refresh on
    # headless machines, so Paid must perform the refresh-token exchange itself
    # before the container starts, then write the rotated credential back to
    # the source directory under a serializing file lock.
    #
    # Unlike Codex (where the CLI runs inside the container and the lock covers
    # the entire exec), the Claude refresh happens at provision-preflight time
    # on the Paid host — the lock serializes concurrent provision attempts that
    # would race on a single-use rotating refresh token.
    #
    # When `AgentHarness::Authentication.exchange_refresh_token` ships
    # (viamin/agent-harness#265), the actual token exchange is delegated there
    # so provider-specific OAuth details stay upstream. Until that ships, the
    # preflight is a no-op guard and the lock infrastructure is still wired.

    # Returns the host-side directory that contains `.credentials.json` for the
    # Claude subscription path, or nil when no credential file is present.
    def claude_credentials_source_path
      host = claude_config_host_path
      return host if host.present? && File.file?(File.join(host, ".credentials.json"))

      local = claude_local_config_path
      return local if local.present? && File.file?(File.join(local, ".credentials.json"))

      nil
    end

    # Parses the native `.credentials.json` shape written by the Claude CLI.
    # The real format nests tokens under `claudeAiOauth`; the current upstream
    # `AgentHarness::Authentication.auth_status(:claude)` reads a flat shape
    # and incorrectly reports "No authentication token found" for real creds.
    #
    # TODO(viamin/agent-harness#265): replace with
    # `AgentHarness::Authentication.auth_status(:claude)` once the upstream
    # shape gap is resolved.
    def claude_native_credential_expiry
      source_path = claude_credentials_source_path
      return nil unless source_path

      creds_file = File.join(source_path, ".credentials.json")
      return nil unless File.file?(creds_file)

      raw = JSON.parse(File.read(creds_file))
      expires_raw = raw.dig("claudeAiOauth", "expiresAt") ||
                    raw["expiresAt"] ||
                    raw["expires_at"]
      expires_raw ? Time.parse(expires_raw.to_s) : nil
    rescue JSON::ParserError, ArgumentError, SystemCallError
      nil
    end

    # Returns true when the host-forwarded Claude credential will expire within
    # the given window, meaning a keep-warm refresh should be attempted.
    # Keep this as a plain Integer so lightweight scripts can require this file
    # without booting Rails or loading ActiveSupport core extensions.
    CLAUDE_CREDENTIAL_REFRESH_WINDOW = 6 * 60 * 60

    def claude_credentials_near_expiry?(refresh_window: CLAUDE_CREDENTIAL_REFRESH_WINDOW)
      expiry = claude_native_credential_expiry
      return false if expiry.nil? # Unknown expiry — don't speculate

      expiry < (Time.now + refresh_window)
    end

    # Computes a deterministic, source-path-scoped lockfile path for the Claude
    # credential, preventing different source directories from contending on the
    # same lock. Mirrors codex_auth_lockfile_path.
    CLAUDE_AUTH_LOCK_BASE_PATH = "/tmp/claude-auth"

    def claude_auth_lockfile_path
      source_path = claude_credentials_source_path
      unless source_path
        return "#{CLAUDE_AUTH_LOCK_BASE_PATH}-missing.lock"
      end

      digest = Digest::SHA256.hexdigest(source_path)[0, 16]
      "#{CLAUDE_AUTH_LOCK_BASE_PATH}-#{digest}.lock"
    end

    # Serializes concurrent keep-warm attempts on the same source credential.
    # After the lock is acquired, yields; if the lock times out, yields anyway
    # (the holder may have already refreshed the credential, or the exchange
    # will fail with refresh_token_reused which is classified as auth_expired).
    #
    # Mirrors with_codex_auth_lock.
    CLAUDE_AUTH_LOCK_TIMEOUT = 30 # seconds

    def with_claude_auth_lock
      lockfile = claude_auth_lockfile_path
      lock_timeout = CLAUDE_AUTH_LOCK_TIMEOUT
      lease_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      File.open(lockfile, File::WRONLY | File::CREAT, 0o600) do |f|
        log_system("container.claude_auth_lock.waiting", lockfile: lockfile, lock_timeout_seconds: lock_timeout)

        acquired = false
        acquired = acquire_lock_with_timeout(f, lock_timeout)

        if acquired
          log_system("container.claude_auth_lock.acquired", lockfile: lockfile)
          record_claude_lease_attempt!(state: RunnerAuthAttempt::LEASE_ACQUIRED, started_at: lease_started_at,
            metadata: { lockfile: lockfile })
          yield
        else
          log_system("container.claude_auth_lock.timeout",
            lockfile: lockfile,
            lock_timeout_seconds: lock_timeout)
          log_system("container.claude_auth_lock_timeout_proceeding_without_lock",
            source_path: claude_credentials_source_path)
          record_claude_lease_attempt!(state: RunnerAuthAttempt::LEASE_TIMEOUT, started_at: lease_started_at,
            metadata: { lockfile: lockfile, lock_timeout_seconds: lock_timeout })
          yield
        end
      ensure
        if acquired
          f.flock(File::LOCK_UN)
          acquired = false
          log_system("container.claude_auth_lock.released", lockfile: lockfile)
        end
      end
    end

    def record_claude_lease_attempt!(state:, started_at:, metadata: {})
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      result = case state
      when RunnerAuthAttempt::LEASE_ACQUIRED then RunnerAuthAttempt::RESULT_LEASE_ACQUIRED
      when RunnerAuthAttempt::LEASE_WAITED then RunnerAuthAttempt::RESULT_LEASE_WAITED
      when RunnerAuthAttempt::LEASE_TIMEOUT then RunnerAuthAttempt::RESULT_LEASE_TIMEOUT
      else RunnerAuthAttempt::RESULT_FAILED
      end

      record_auth_attempt!(
        runner_key: "claude",
        attempt_stage: RunnerAuthAttempt::STAGE_LEASE,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        lease_state: state,
        result: result,
        duration_ms: duration_ms,
        metadata: metadata
      )
    end

    # Provision-preflight keep-warm: if the host-forwarded Claude credential is
    # near expiry, attempt a refresh-token exchange under a serializing file lock.
    # The rotated credential is written back to the source directory by the
    # upstream `exchange_refresh_token` call so the subsequent seed picks it up.
    #
    # No-ops if:
    # - No host-forwarded Claude credential is present
    # - The credential expiry is unknown (non-`claudeAiOauth` shape)
    # - The credential has more than CLAUDE_CREDENTIAL_REFRESH_WINDOW remaining
    # - `AgentHarness::Authentication` does not yet support `exchange_refresh_token`
    #   (viamin/agent-harness#265)
    def refresh_claude_credentials_if_near_expiry!
      return unless claude_subscription_auth?
      return unless claude_credentials_near_expiry?

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      refresh_state = RunnerAuthAttempt::REFRESH_NOT_NEEDED

      with_claude_auth_lock do
        # Re-check after acquiring the lock: another Paid instance may have
        # already refreshed this credential while we waited.
        unless claude_credentials_near_expiry?
          record_auth_attempt!(
            runner_key: "claude",
            attempt_stage: RunnerAuthAttempt::STAGE_REFRESH,
            auth_source: :host_forwarded,
            materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
            refresh_state: RunnerAuthAttempt::REFRESH_NOT_NEEDED,
            result: RunnerAuthAttempt::RESULT_SKIPPED,
            metadata: { source: "host_mount", reason: "already_refreshed" }
          )
          return
        end

        outcome = exchange_claude_refresh_token!
        refresh_state = outcome ? RunnerAuthAttempt::REFRESH_REFRESHED : RunnerAuthAttempt::REFRESH_REFRESH_FAILED
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        record_auth_attempt!(
          runner_key: "claude",
          attempt_stage: RunnerAuthAttempt::STAGE_REFRESH,
          auth_source: :host_forwarded,
          materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
          refresh_state: refresh_state,
          result: outcome ? RunnerAuthAttempt::RESULT_REFRESHED : RunnerAuthAttempt::RESULT_REFRESH_FAILED,
          failure_reason: outcome ? nil : "exchange_refresh_token_failed",
          duration_ms: duration_ms,
          metadata: { source: "host_mount" }
        )
      end
    end

    # Calls the upstream refresh-token exchange API and writes the rotated
    # credential back to the source. Requires
    # `AgentHarness::Authentication.exchange_refresh_token` (viamin/agent-harness#265).
    # Until that is supported, logs and returns false.
    def exchange_claude_refresh_token!
      unless claude_refresh_exchange_supported?
        log_system("container.claude_auth_refresh.unsupported",
          note: "viamin/agent-harness#265 not yet available; skipping keep-warm exchange")
        return false
      end

      source_path = claude_credentials_source_path
      return false unless source_path

      with_env("CLAUDE_CONFIG_DIR", source_path) do
        AgentHarness::Authentication.exchange_refresh_token(:claude)
      end
      log_system("container.claude_auth_refreshed", source_path: source_path)
      true
    rescue AgentHarness::AuthenticationError => e
      log_system("container.claude_auth_refresh_failed",
        error: e.message,
        source_path: source_path,
        note: "classify as auth_expired via refresh_token_reused pattern if applicable")
      false
    rescue AgentHarness::Error, SystemCallError, JSON::ParserError => e
      log_system("container.claude_auth_refresh_failed", error: e.message, source_path: source_path)
      false
    end

    def claude_refresh_exchange_supported?
      AgentHarness::Authentication.respond_to?(:exchange_refresh_token) &&
        AgentHarness::Authentication.respond_to?(:exchange_refresh_token_supported?) &&
        AgentHarness::Authentication.exchange_refresh_token_supported?(:claude)
    end

    def with_env(key, value)
      previous = ENV[key]
      ENV[key] = value
      yield
    ensure
      previous.nil? ? ENV.delete(key) : ENV[key] = previous
    end

    def subscription_auth_provider_for(runner_key)
      Runners::SubscriptionAuthProviders.for_runner(runner_key)
    end

    def claude_subscription_auth_provider
      subscription_auth_provider_for("claude")
    end

    # Single source of truth for the Codex heartbeat notify line used in both
    # fresh-config (seed_codex_config!) and subscription-auth (seed_codex_notify_hook!)
    # paths. The agent-harness notify_hook_content returns only a TOML section
    # header; the actual heartbeat command is Paid-specific.
    def codex_notify_line
      self.class.codex_notify_line
    end

    def copilot_config_host_path
      @copilot_config_host_path ||= begin
        ENV["COPILOT_HOME"].presence ||
          ENV["COPILOT_CONFIG_DIR"].presence ||
          detect_host_config_path("/.copilot")
      end
    end

    def copilot_local_config_path
      @copilot_local_config_path ||= local_config_path(".copilot")
    end

    def copilot_subscription_auth?
      if managed_subscription_runner_auth_enabled_for?("copilot")
        return true if copilot_managed_secret && !copilot_managed_secret.blank?
      end

      paths = [ copilot_config_host_path, copilot_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, "config.json")) }
    end

    def copilot_managed_config_json
      parsed = copilot_managed_secret
      return unless parsed&.copilot_config?

      parsed.config_json
    end

    def copilot_managed_runner_credential
      return @copilot_managed_runner_credential if defined?(@copilot_managed_runner_credential)

      @copilot_managed_runner_credential = managed_subscription_credential_scope_for("copilot")&.active
        &.order(created_at: :desc, id: :desc)&.first
    end

    def copilot_managed_secret
      return @copilot_managed_secret if defined?(@copilot_managed_secret)

      secret = copilot_managed_runner_credential&.token.to_s
      @copilot_managed_secret = secret.present? ? CopilotCredentials::Secret.parse(secret) : nil
    end

    def detect_host_config_path(suffix)
      detected_config_mount(suffix)&.dig("Source")
    end

    def detected_codex_auth_mount
      mount = detected_config_mount("/.codex")
      return unless mount

      CodexAuthMount.new(host_path: mount["Source"], config_path: mount["Destination"])
    end

    def detected_config_mount(suffix)
      hostname = Socket.gethostname
      container = local_runtime_backend.get_container(hostname)
      mounts = container.info["Mounts"] || []
      mounts.find { |mount| mount["Destination"]&.end_with?(suffix) }
    rescue Docker::Error::DockerError
      nil
    end

    def docker_host_path_for(path)
      return if path.blank?

      expanded = File.expand_path(path)
      mounts = current_container_mounts
      return expanded if mounts.nil?

      mount = mounts.filter_map do |candidate|
        destination = candidate["Destination"].to_s
        source = candidate["Source"].to_s
        next if destination.blank? || source.blank?

        destination = File.expand_path(destination)
        next unless expanded == destination || expanded.start_with?("#{destination}/")

        [ destination.length, File.join(source, expanded.delete_prefix(destination).delete_prefix("/")) ]
      end.max_by(&:first)

      mount&.last
    end

    def current_container_mounts
      return @current_container_mounts if defined?(@current_container_mounts)

      hostname = Socket.gethostname
      container = local_runtime_backend.get_container(hostname)
      @current_container_mounts = container.info["Mounts"] || []
    rescue Docker::Error::DockerError
      @current_container_mounts = nil
    end

    def local_config_path(dirname)
      path = File.join(ENV.fetch("HOME", "/home/vscode"), dirname)
      File.directory?(path) ? path : nil
    end

    public

    # Resolves service container IPs plus the preview-tunnel destination for
    # firewall rules. Exposed as public so the runner can merge these
    # destinations into the firewall rule set without reaching into Provision
    # internals or knowing about preview tunnels (RDR-054).
    def firewall_service_destinations
      destinations = resolve_service_destinations
      return destinations unless preview_tunnel?

      remote_destination = Previews::TunnelManager.client_remote_destination(
        backend:,
        restricted: network_contract.restricted?
      )
      destinations + [ { ip: remote_destination.fetch(:host), port: remote_destination.fetch(:port) } ]
    end

    private
    def resolve_service_destinations
      return [] unless agent_run

      container_ids = agent_run.service_container_ids
      return [] if container_ids.blank?

      ServiceContainer.where(id: container_ids, status: "running").filter_map do |sc|
        next if sc.docker_container_id.blank?

        ip = docker_container_ip(sc.docker_container_id)
        next if ip.blank?

        { ip: ip, port: sc.port }
      end
    end

    def docker_container_ip(docker_id)
      info = backend.get_container(docker_id).info
      networks = info.dig("NetworkSettings", "Networks") || {}
      network_info = networks[container_network]
      network_info&.dig("IPAddress")
    rescue Docker::Error::DockerError
      nil
    end

    def container_name
      run_part = agent_run ? agent_run.id : "pool-#{pool_entry.id}"
      "paid-#{project.id}-#{run_part}-#{SecureRandom.hex(4)}"
    end

    def ensure_network!
      # When the constructor was given a +networking_policy+, the runner owns
      # the network-ensure + firewall-apply translation. Returning here keeps
      # the existing call site in +#provision+ working without duplicating
      # the side effect.
      return if @networking_policy

      NetworkPolicy.ensure_network!(network: network_name, backend: backend)
      log_system("container.network.ready", network: network_name, mode: network_contract.mode)
    rescue NetworkPolicy::Error => e
      raise ProvisionError, "Network setup failed: #{e.message}"
    end

    def apply_network_restrictions!
      # See +#ensure_network!+: the runner owns the firewall translation
      # when +networking_policy+ is supplied.
      return if @networking_policy
      return unless network_contract.firewall?

      NetworkPolicy.apply_firewall_rules(
        container,
        service_destinations: firewall_service_destinations,
        backend: backend
      )
      log_system("container.firewall.applied", container_id: container.id)
    rescue NetworkPolicy::Error => e
      log_system("container.firewall.failed", error: e.message)
      # Firewall rules are defense-in-depth — they restrict outbound traffic
      # but the container is already on a restricted Docker network. Raising
      # in dev/test/CI would block local development on hosts without iptables
      # (e.g., macOS Docker Desktop, some CI runners). Production always
      # raises: a firewall gap on a live deployment is a security incident.
      raise ProvisionError, "Firewall setup failed: #{e.message}" if Rails.env.production?
    end

    def fetch_exit_code
      container.refresh!
      container.info.dig("State", "ExitCode") || -1
    rescue Docker::Error::DockerError
      -1
    end

    def build_streaming_event_processor(command)
      return nil unless agent_run && streaming_event_command?(command)
      return nil if agent_run.custom_prompt == AgentRun::SMOKE_TEST_CUSTOM_PROMPT

      StreamingEventProcessor.new(
        agent_run: agent_run,
        logger: method(:log_system)
      )
    end

    def local_runtime_backend
      @local_runtime_backend ||= Containers.backend_for("local")
    rescue Containers::Backends::Resolver::UnknownBackendError
      Containers.backend
    end

    def streaming_event_command?(command)
      codex_exec_command?(command)
    end

    def trim_streaming_line_buffer!(buffer)
      return unless buffer.bytesize > MAX_STREAMING_LINE_BUFFER_BYTES

      dropped_bytes = buffer.bytesize
      buffer.clear
      log_system("container.execute.streaming_buffer_reset", dropped_bytes: dropped_bytes)
    end

    def log_system(message, **metadata)
      Rails.logger.info(
        message: "container_manager.#{message}",
        agent_run_id: agent_run&.id,
        project_id: project.id,
        **metadata
      )

      agent_run&.log!("system", message, metadata: metadata)
    end

    # RDR-041 / #2959 — emits an explicit `auth_source` field in provisioning
    # log payloads so operators can group credential-seeding events by managed
    # vs host_forwarded vs api_key_proxy without joining against runner_auth_attempts.
    # Returns {} when no auth_source is supplied so the helper can be safely
    # splatted into any log call.
    def auth_source_log_payload(auth_source)
      return {} if auth_source.blank?

      { auth_source: auth_source.to_s }
    end

    # RDR-041 / #2960 — single seam for writing runner auth attempt telemetry
    # from the provision flow. Always normalizes to the AuthSource vocabulary so
    # analytics can group by managed vs host_forwarded vs api_key_proxy.
    def record_auth_attempt!(runner_key:, attempt_stage:, result:,
      auth_source: nil, materialization_mode: nil, runner_credential: nil,
      refresh_state: nil, lease_state: nil, failure_reason: nil,
      duration_ms: nil, retry_count: 0, metadata: {})
      resolved_auth_source = if auth_source.is_a?(Runners::SubscriptionAuthEligibility::AuthSource)
        auth_source
      elsif auth_source.is_a?(Symbol) || auth_source.is_a?(String)
        Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: auth_source.to_sym,
          credential_state: :active
        )
      else
        Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: :host_forwarded
        )
      end

      Runners::AuthAttemptRecorder.call(
        agent_run: agent_run,
        project: project,
        backend: backend,
        runner_key: runner_key,
        attempt_stage: attempt_stage,
        auth_source: resolved_auth_source,
        materialization_mode: materialization_mode,
        runner_credential: runner_credential,
        refresh_state: refresh_state,
        lease_state: lease_state,
        result: result,
        failure_reason: failure_reason,
        duration_ms: duration_ms,
        retry_count: retry_count,
        metadata: metadata
      )
    end

    def log_output(type, content)
      return if content.blank?

      agent_run&.log!(type.to_s, content)
    end

    def normalize_output_chunk(chunk)
      text = chunk.to_s

      if text.encoding == Encoding::UTF_8 && text.valid_encoding?
        return text unless text.include?("\x00")

        return text.delete("\x00")
      end

      normalized_text = text.dup.force_encoding(Encoding::UTF_8).scrub
      return normalized_text unless normalized_text.include?("\x00")

      normalized_text.delete("\x00")
    end

    def log_partial_output(stdout_buffer, stderr_buffer)
      log_output(:stdout, stdout_buffer.join) if stdout_buffer.any?
      log_output(:stderr, stderr_buffer.join) if stderr_buffer.any?
    end

    # Checks if the watchdog set a timeout reason and raises the appropriate error.
    # Called after container.exec returns or in rescue blocks, since the watchdog
    # stops the container to unblock the exec (which may surface as a Docker error
    # or a normal return with a non-zero exit code).
    #
    # timeout_check.timeout_reason_ref is a lambda that reads the shared
    # timeout_reason variable; this method invokes it while holding
    # timeout_check.mutex so we see the latest value rather than a stale snapshot.
    def raise_if_watchdog_timeout!(timeout_check)
      reason = timeout_check.mutex.synchronize { timeout_check.timeout_reason_ref.call }
      return unless reason

      case reason
      when :startup
        raise StartupTimeoutError.new(
          "No output received within #{timeout_check.startup_timeout} seconds",
          diagnostics: timeout_diagnostics_for_state(timeout_check, output_received: false)
        )
      when :idle
        raise IdleTimeoutError.new(
          "No output received for #{timeout_check.idle_timeout} seconds after last activity",
          diagnostics: timeout_diagnostics_for_state(timeout_check, output_received: true)
        )
      when :wall_clock
        elapsed_seconds = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - timeout_check.started_at)).round(1)
        hb_age = heartbeat_age_seconds(timeout_check.heartbeat_path)
        log_system("container.execute.timeout",
          timeout_type: "wall_clock",
          timeout: timeout_check.timeout,
          elapsed_seconds: elapsed_seconds,
          heartbeat_active: hb_age && hb_age <= elapsed_seconds,
          heartbeat_age_seconds: hb_age&.round(1))
        raise TimeoutError.new(
          "Command timed out after #{timeout_check.timeout} seconds",
          diagnostics: timeout_diagnostics_for_state(
            timeout_check,
            output_received: hb_age && hb_age <= elapsed_seconds
          )
        )
      end
    end

    # Post-exec deadline check for when exec returns between watchdog polling
    # ticks. The watchdog sleeps 1s between checks, so a fast-completing exec
    # can slip through with a deadline already exceeded.
    def check_deadline_exceeded!(timeout_check, output_received:, last_activity_at:)
      tc = timeout_check
      return unless tc.startup_timeout || tc.idle_timeout || tc.timeout

      heartbeat_age = heartbeat_age_seconds(tc.heartbeat_path)

      elapsed_since_activity, elapsed_since_start = tc.mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [ now - last_activity_at, now - tc.started_at ]
      end

      # Startup is enforced from the authoritative wall clock (elapsed_since_start),
      # never shrunk by heartbeat freshness — matching the watchdog. A no-output
      # run past startup_timeout is a stuck startup regardless of the heartbeat file.
      if !output_received && tc.startup_timeout && elapsed_since_start >= tc.startup_timeout
        raise StartupTimeoutError.new(
          "No output received within #{tc.startup_timeout} seconds",
          diagnostics: timeout_diagnostics_from_elapsed(
            elapsed_since_start,
            elapsed_since_activity,
            output_received,
            tc.heartbeat_path,
            heartbeat_age
          )
        )
      end

      # Fold in heartbeat activity for idle/wall-clock using the same rules as
      # the watchdog: a file touched during the current exec counts as output,
      # and the idle elapsed window shrinks to the heartbeat's age. A fresh
      # heartbeat also suppresses wall-clock timeout.
      heartbeat_fresh = heartbeat_age && heartbeat_age <= elapsed_since_start
      if heartbeat_fresh
        output_received = true
        elapsed_since_activity = heartbeat_age if heartbeat_age < elapsed_since_activity
      end

      if output_received && tc.idle_timeout && elapsed_since_activity >= tc.idle_timeout
        raise IdleTimeoutError.new(
          "No output received for #{tc.idle_timeout} seconds after last activity",
          diagnostics: timeout_diagnostics_from_elapsed(
            elapsed_since_start,
            elapsed_since_activity,
            output_received,
            tc.heartbeat_path,
            heartbeat_age
          )
        )
      elsif tc.timeout && elapsed_since_start >= tc.timeout && !heartbeat_fresh
        log_system("container.execute.timeout",
          timeout_type: "wall_clock",
          timeout: tc.timeout,
          **timeout_diagnostics_from_elapsed(elapsed_since_start, elapsed_since_activity, output_received, tc.heartbeat_path, heartbeat_age))
        raise TimeoutError.new(
          "Command timed out after #{tc.timeout} seconds",
          diagnostics: timeout_diagnostics_from_elapsed(
            elapsed_since_start,
            elapsed_since_activity,
            output_received,
            tc.heartbeat_path,
            heartbeat_age
          )
        )
      end
    end

    def timeout_diagnostics_for_state(timeout_check, output_received:)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed_since_start = now - timeout_check.started_at
      heartbeat_age = heartbeat_age_seconds(timeout_check.heartbeat_path)
      output_received = timeout_check.output_received_ref&.call || output_received
      elapsed_since_activity = if output_received
        last_activity_at = timeout_check.last_activity_ref&.call || timeout_check.started_at
        [ now - last_activity_at, heartbeat_age || Float::INFINITY ].min
      else
        elapsed_since_start
      end

      timeout_diagnostics_from_elapsed(
        elapsed_since_start,
        elapsed_since_activity,
        output_received,
        timeout_check.heartbeat_path,
        heartbeat_age
      )
    end

    # Starts a watchdog thread that monitors output activity and stops the
    # container when the agent appears stuck. Stopping the container closes
    # the Docker exec HTTP stream, unblocking the main thread's container.exec
    # call. The timeout_reason_setter lambda records which timeout triggered
    # so the main thread can raise the right error class.
    #
    # The exec_completed_ref lambda is checked before acting on a timeout to
    # avoid late/false triggers after exec has already returned normally.
    #
    # This approach is more reliable than Thread.raise, which can be swallowed
    # or re-wrapped by the HTTP library (Excon) during blocking I/O.
    #
    # Returns nil if no timeouts are configured.
    def start_watchdog(ctx)
      return nil unless ctx.startup_timeout || ctx.idle_timeout || ctx.wall_clock_timeout

      Thread.new do
        loop do
          begin
            sleep watchdog_poll_interval

            # Read heartbeat mtime outside the mutex to avoid holding the lock
            # across slow filesystem operations.
            heartbeat_age = heartbeat_age_seconds(ctx.heartbeat_path)

            should_fire = ctx.mutex.synchronize do
              if ctx.exec_completed_ref.call
                false
              else
                now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                total_elapsed = now - ctx.started_at_ref.call
                output_received = ctx.output_received_ref.call

                # The startup timeout is enforced from a single authoritative
                # clock: if no real stdout/stderr has been received within
                # startup_timeout of exec start, the agent is stuck in startup
                # and is killed now. Heartbeat-file freshness must NOT extend
                # this window — a file kept fresh past startup_timeout (or one
                # that only goes stale much later) previously suppressed the
                # :startup decision for up to the wall-clock cap, then fired it
                # with a huge elapsed still labeled "within startup_timeout".
                reason = if !output_received && ctx.startup_timeout && total_elapsed >= ctx.startup_timeout
                  :startup
                else
                  # Once real output flows (or the agent is actively touching the
                  # heartbeat file), a fresh heartbeat counts as activity: it
                  # suppresses idle timeout and, for actively-working agents,
                  # wall-clock timeout. A heartbeat touched during the current
                  # exec has age <= total_elapsed; one left over from before
                  # exec started does not and is ignored.
                  elapsed = now - ctx.last_activity_ref.call
                  heartbeat_fresh = heartbeat_age && heartbeat_age <= total_elapsed
                  if heartbeat_fresh
                    output_received = true
                    elapsed = heartbeat_age if heartbeat_age < elapsed
                  end

                  if output_received && ctx.idle_timeout && elapsed >= ctx.idle_timeout
                    :idle
                  elsif ctx.wall_clock_timeout && total_elapsed >= ctx.wall_clock_timeout && !heartbeat_fresh
                    :wall_clock
                  end
                end

                if reason
                  ctx.timeout_reason_setter.call(reason)
                  true
                else
                  false
                end
              end
            end

            next unless should_fire

            # Re-check exec_completed under the mutex to close the race window
            # between should_fire computation and container.stop — exec may have
            # returned between releasing the mutex above and reaching here.
            break if ctx.mutex.synchronize { ctx.exec_completed_ref.call }

            watchdog_stop_container!(ctx.container)

            break
          rescue => e
            log_system(
              "container.watchdog.poll_failed",
              error: e.message,
              error_class: e.class.name
            )
          end
        end
      end
    end

    # How often the watchdog thread checks for timeouts, in seconds.
    # Extracted as a method so tests can override with a shorter interval.
    def watchdog_poll_interval
      1
    end

    # Attempts to stop a container with retries. All attempts use the backend
    # abstraction (not container.kill) so Swarm service references are resolved
    # correctly. stop(timeout: 0) already sends SIGTERM then immediate SIGKILL.
    # Returns true if the container was stopped.
    def watchdog_stop_container!(container)
      WATCHDOG_STOP_ATTEMPTS.times do |attempt|
        backend.stop_container(container, timeout: 0)
        return true
      rescue Docker::Error::DockerError => e
        log_system("container.watchdog.stop_failed",
          error: e.message,
          attempt: attempt + 1,
          max_attempts: WATCHDOG_STOP_ATTEMPTS)
        sleep(1) if attempt < WATCHDOG_STOP_ATTEMPTS - 1
      end

      log_system("container.watchdog.stop_exhausted",
        message: "All #{WATCHDOG_STOP_ATTEMPTS} stop attempts failed")
      false
    end

    def timeout_diagnostics(started_at, output_received, last_activity_at, heartbeat_path)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed_since_start = (now - started_at).round(1)
      elapsed_since_activity = output_received ? (now - last_activity_at).round(1) : nil
      hb_age = heartbeat_age_seconds(heartbeat_path)

      {
        elapsed_seconds: elapsed_since_start,
        idle_seconds: elapsed_since_activity,
        output_received: output_received,
        heartbeat_active: hb_age && hb_age <= elapsed_since_start,
        heartbeat_age_seconds: hb_age&.round(1)
      }
    end

    def timeout_diagnostics_from_elapsed(elapsed_since_start, elapsed_since_activity, output_received, heartbeat_path, heartbeat_age)
      {
        elapsed_seconds: elapsed_since_start.round(1),
        idle_seconds: output_received ? elapsed_since_activity.round(1) : nil,
        output_received: output_received,
        heartbeat_active: heartbeat_age && heartbeat_age <= elapsed_since_start,
        heartbeat_age_seconds: heartbeat_age&.round(1)
      }
    end

    def output_summary_diagnostics(stdout_buffer, stderr_buffer)
      stderr_text = stderr_buffer.join
      {
        stdout_bytes: stdout_buffer.sum(&:bytesize),
        stderr_bytes: stderr_buffer.sum(&:bytesize),
        last_stderr: stderr_text.present? ? stderr_text.last(200).encode("UTF-8", invalid: :replace) : nil
      }
    end

    # Returns the age in seconds of the heartbeat file at +heartbeat_path+, or
    # +nil+ when no path is configured or the file is unreadable.
    #
    # File mtimes are wall-clock timestamps, so we sample their initial age
    # once and then advance that age using the monotonic clock while the mtime
    # remains unchanged. This avoids repeated exposure to wall-clock jumps
    # during watchdog polling.
    def heartbeat_age_seconds(heartbeat_path)
      return nil if heartbeat_path.blank?

      mtime = heartbeat_mtime(heartbeat_path)
      return nil unless mtime

      observed_at_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      observed_age = Time.now - mtime

      @heartbeat_age_cache_mutex.synchronize do
        cached = @heartbeat_age_cache[heartbeat_path]

        if cached && cached[:mtime] == mtime
          cached[:age_seconds] + (observed_at_monotonic - cached[:observed_at_monotonic])
        else
          @heartbeat_age_cache[heartbeat_path] = {
            mtime: mtime,
            age_seconds: observed_age,
            observed_at_monotonic: observed_at_monotonic
          }
          observed_age
        end
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
      nil
    end

    def heartbeat_mtime(heartbeat_path)
      if container_heartbeat_path?(heartbeat_path)
        container_heartbeat_mtime(heartbeat_path)
      else
        File.mtime(heartbeat_path)
      end
    end

    def container_heartbeat_path?(heartbeat_path)
      heartbeat_path.start_with?("#{HEARTBEAT_MOUNT_POINT}/")
    end

    def container_heartbeat_mtime(heartbeat_path)
      stdout, = backend.exec_in_container(
        container,
        [ "sh", "-lc", "test -e #{Shellwords.escape(heartbeat_path)} && stat -c %Y #{Shellwords.escape(heartbeat_path)}" ],
        wait: 5,
        user: "agent"
      )
      mtime_seconds = stdout.join.to_s.strip
      return nil if mtime_seconds.blank?

      Time.at(Integer(mtime_seconds))
    rescue Docker::Error::DockerError, ArgumentError
      nil
    end

    # Stops the watchdog thread and waits for it to exit cleanly.
    def stop_watchdog(watchdog)
      return unless watchdog&.alive?

      watchdog.kill
      unless watchdog.join(1)
        log_system("container.watchdog.zombie", message: "Watchdog thread did not terminate within 1s")
      end
    end

    # Simple result object for method returns
    class Result
      attr_reader :data, :error

      def initialize(success:, data: {}, error: nil)
        @success = success
        @data = data
        @error = error
      end

      def success?
        @success
      end

      def failure?
        !@success
      end

      def [](key)
        data[key]
      end

      def self.success(**data)
        new(success: true, data: data)
      end

      def self.failure(error:, **data)
        new(success: false, data: data, error: error)
      end
    end
  end
end
