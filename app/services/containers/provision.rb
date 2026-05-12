# frozen_string_literal: true

require "base64"
require "digest"
require "docker-api"
require "json"
require "open3"
require "securerandom"
require "shellwords"

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
    CODEX_NOTIFY_LINE = 'notify = ["sh", "-lc", "date +%s > /paid-heartbeat/.paid-heartbeat"]'
    HEARTBEAT_MOUNT_POINT = "/paid-heartbeat"
    MAX_STREAMING_LINE_BUFFER_BYTES = 64 * 1024

    # Maximum clock skew tolerance (seconds) between the Docker daemon's
    # `wait:` timer and Ruby's CLOCK_MONOTONIC when reclassifying a Docker
    # transport error as a timeout. Kept small to avoid false reclassification.
    DOCKER_TIMEOUT_SKEW_TOLERANCE = 0.5

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
    class OutputAbortError < Error
      attr_reader :matched_output

      def initialize(msg = "Process aborted due to fatal output pattern", matched_output: nil)
        @matched_output = matched_output
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
      image: "paid-agent:latest",
      user: "agent",
      workspace_mount: "/workspace"
    }.freeze

    attr_reader :agent_run, :project, :worktree_path, :container, :options, :workspace_volume, :pool_entry, :heartbeat_dir_host

    def self.network_for(agent_run:)
      new(agent_run: agent_run).network_name
    end

    def self.codex_notify_line
      CODEX_NOTIFY_LINE
    end

    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param worktree_path [String, nil] Path to an existing worktree to bind-mount.
    #   When nil, a Docker named volume is created for in-container git clone.
    # @param options [Hash] Override default container options
    # @option options [Integer] :memory_bytes Memory limit in bytes
    # @option options [Integer] :cpu_quota CPU quota (100_000 per CPU)
    # @option options [Integer] :pids_limit Maximum number of processes
    # @option options [Integer] :timeout_seconds Default command timeout
    # @option options [String] :image Docker image to use
    def initialize(agent_run: nil, project: nil, worktree_path: nil, pool_entry: nil, workspace_volume: nil, **options)
      raise ArgumentError, "agent_run or project is required" if agent_run.nil? && project.nil?

      if options.key?(:network)
        Rails.logger.warn(
          message: "container_manager.container.network_option_ignored",
          agent_run_id: agent_run&.id,
          hint: "The :network option is ignored; containers use the network selected by runner auth mode"
        )
        options.delete(:network)
      end
      @agent_run = agent_run
      @project = project || agent_run.project
      @worktree_path = worktree_path
      @pool_entry = pool_entry
      @workspace_volume = workspace_volume
      @pool_mode = options.delete(:pool_mode) { false }
      @options = DEFAULTS.merge(resolve_user_setting_overrides).merge(options)
      @container = nil
      @heartbeat_age_cache = {}
      @heartbeat_age_cache_mutex = Mutex.new
      @heartbeat_dir_host = nil
    end

    # Provisions a new container with security hardening.
    # Ensures the selected network exists before creating the container,
    # and applies firewall rules for restricted proxy-mode runs after start.
    #
    # @return [Result] Result object with success/failure status
    def provision
      log_system("container.provision.start", image: options[:image])

      prepare_heartbeat_dir!
      prepare_workspace!
      ensure_network!
      @container = create_container
      start_container
      fix_all_ownership!
      seed_opencode_database!
      seed_codex_credentials!
      seed_gemini_credentials!
      seed_copilot_credentials!
      seed_claude_credentials!
      apply_network_restrictions!

      log_system("container.provision.success", container_id: container.id)
      Result.success(container_id: container.id)
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
    # @return [Result] Result with stdout, stderr, and exit_code
    # @raise [StartupTimeoutError] when no output is received within +startup_timeout+ seconds
    # @raise [IdleTimeoutError] when output stops for more than +idle_timeout+ seconds
    # @raise [TimeoutError] when total wall-clock +timeout+ is exceeded
    def execute(command, timeout: nil, startup_timeout: nil, idle_timeout: nil, stream: true, env: {}, preparation: nil, heartbeat_path: nil, abort_patterns: nil)
      raise ProvisionError, "Container not provisioned" unless container

      with_codex_auth_lock(command) { execute_unlocked(command, timeout:, startup_timeout:, idle_timeout:, stream:, env:, preparation:, heartbeat_path:, abort_patterns:) }
    end

    def network_name
      network_contract.network
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

    private def execute_unlocked(command, timeout: nil, startup_timeout: nil, idle_timeout: nil, stream: true, env: {}, preparation: nil, heartbeat_path: nil, abort_patterns: nil)
      timeout ||= options[:timeout_seconds]
      cmd_array = command.is_a?(Array) ? command : [ "sh", "-c", command ]
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

        exec_result = container.exec(cmd_array, exec_options) do |stream_type, chunk|
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
                    container.stop(timeout: 0)
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
                container.stop(timeout: 0)
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
              container.stop(timeout: 0)
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
            matched_output: "streaming_event:#{streaming_abort_event_type || 'turn_failed'}"
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
          Result.failure(
            error: "Command exited with code #{exit_code}",
            stdout: stdout,
            stderr: stderr,
            exit_code: exit_code
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
            matched_output: "streaming_event:#{streaming_abort_event_type || 'turn_failed'}"
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

    # Stops and removes the container, cleaning up resources.
    #
    # @param force [Boolean] Force kill if container doesn't stop gracefully
    # @return [void]
    def cleanup(force: false)
      cleanup_heartbeat_dir!
      return unless container

      log_system("container.cleanup.start", container_id: container.id)

      begin
        stop_container(force: force)
        container.delete(force: force, v: true)
        log_system("container.cleanup.success")
      rescue Docker::Error::DockerError => e
        log_system("container.cleanup.failed", error: e.message)
        begin
          container.delete(force: true, v: true)
        rescue Docker::Error::DockerError
          # Container may already be gone
        end
      ensure
        @container = nil
        cleanup_workspace_volume
        cleanup_claimed_pool_entry
      end
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
      container = Docker::Container.get(container_id)
      pool_entry ||= ContainerPoolEntry.claimed.find_by(agent_run: agent_run, container_id: container_id)
      workspace_volume ||= pool_entry&.workspace_volume

      new(agent_run: agent_run, worktree_path: worktree_path, workspace_volume: workspace_volume, pool_entry: pool_entry, **options)
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
      cleanup_error = nil

      Array(cleanup_steps).reverse_each do |step_env|
        # Intentionally keeps only the first error (cleanup_error ||= e) so the
        # caller sees the root-cause failure rather than a cascading one.
        cleanup_error ||= run_preparation_cleanup_step(step_env, env: env)
      end

      return unless cleanup_error

      invalidate_container_after_preparation_cleanup_failure!
      raise cleanup_execution_error(cleanup_error)
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
    def run_preparation_cleanup_step(step_env, env:)
      run_preparation_script(cleanup_script, env: env, script_env: step_env)
      nil
    rescue Docker::Error::DockerError, ExecutionError => e
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
      stdout, stderr, exit_code = container.exec([ "sh", "-lc", script ], exec_options)

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
      settings = AgentRuns::UserSettingsResolver.call(
        project: project, strict: false
      )
      return {} unless settings

      overrides = {}
      overrides[:memory_bytes] = settings.container_memory_bytes if settings.container_memory_bytes.present?
      overrides
    end

    def stop_container(force: false)
      return unless container_running?

      container.stop(timeout: force ? 0 : 10)
    rescue Docker::Error::NotFoundError
      # Container was already removed between running? check and stop
    end

    # Copies credentials and settings from the read-only host mount into the
    # writable ~/.claude tmpfs. Only the files Claude CLI needs for auth and
    # configuration are copied; session/project data is created fresh each run.
    def seed_claude_credentials!
      source_files = %w[.credentials.json settings.json]
      return unless claude_subscription_auth?

      # Prefer the source that actually contains the required credential file
      # so we don't set PAID_CLAUDE_SUBSCRIPTION_AUTH=1 without seeding creds.
      host = claude_config_host_path
      if host.present? && File.file?(File.join(host, ".credentials.json"))
        seed_host_credentials!(
          staging_path: "/home/agent/.claude-host",
          target_path: "/home/agent/.claude",
          files: source_files,
          success_log_key: "container.claude_credentials_seeded",
          failure_log_key: "container.claude_credentials_seed_failed"
        )
      else
        seed_local_credentials!(
          source_path: claude_local_config_path,
          target_path: "/home/agent/.claude",
          files: source_files,
          success_log_key: "container.claude_credentials_seeded",
          failure_log_key: "container.claude_credentials_seed_failed"
        )
      end
    end

    # Writes a minimal Codex config into the writable ~/.codex tmpfs so the
    # CLI uses API-key auth against Paid's OpenAI proxy instead of cached
    # ChatGPT credentials. This keeps containerized runs aligned with Paid's
    # runner configuration.
    def seed_codex_config!
      config_toml = codex_harness_provider.config_file_content(
        model_provider: "paid",
        base_url: "#{proxy_base_url}/api/proxy/openai",
        env_key: "OPENAI_API_KEY",
        wire_api: "responses"
      )
      content = "#{codex_notify_line}\n\n#{config_toml}"

      write_container_file("/home/agent/.codex/config.toml", content)
      log_system("container.codex_config_seeded")
    rescue Docker::Error::DockerError => e
      log_system("container.codex_config_seed_failed", error: e.message)
    end

    def seed_codex_credentials!
      unless codex_subscription_auth?
        raise_unshared_codex_auth_error! if unshared_codex_subscription_auth?

        seed_codex_config!
        return
      end

      mount = codex_subscription_auth_mount
      log_system("container.codex_credentials_shared", source_path: mount.host_path)
      seed_sanitized_codex_config!(source_path: mount.config_path)

      seed_codex_notify_hook!
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
      sanitized = strip_codex_project_sections(content)
      write_container_file("/home/agent/.codex/config.toml", sanitized)
      log_system("container.codex_config_sanitized")
    rescue Docker::Error::DockerError, SystemCallError => e
      log_system("container.codex_config_sanitization_failed", error: e.message)
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

    # Appends the Codex notify hook to config.toml inside the container.
    # For subscription auth, the base config may come from the host or local
    # copy and may include an older notify shape. This method rewrites the
    # notify command idempotently so the watchdog receives heartbeats during
    # Codex turns without leaving duplicate TOML keys.
    # Creates config.toml when subscription auth only provided auth.json.
    def seed_codex_notify_hook!
      escaped_notify = Shellwords.escape(codex_notify_line)
      result = container.exec(
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

    # Serializes only Codex CLI executions that share a host-backed auth.json.
    # Other container commands keep full parallelism, and different credential
    # directories map to different lockfiles.
    #
    # Uses a non-blocking lock with retries instead of indefinite blocking to
    # prevent a hung container from stalling all other runs sharing the same
    # auth.json. After lock_timeout_seconds, logs a warning and proceeds
    # without the lock — a concurrent OAuth refresh may fail with
    # refresh_token_reused, which Paid classifies as auth_expired and handles
    # via the standard runner fallback path.
    def with_codex_auth_lock(command)
      return yield unless codex_auth_lock_required?(command)

      lockfile = codex_auth_lockfile_path
      lock_timeout = codex_auth_lock_timeout

      File.open(lockfile, File::WRONLY | File::CREAT, 0o600) do |f|
        log_system("container.codex_auth_lock.waiting", lockfile: lockfile, lock_timeout_seconds: lock_timeout)

        acquired = false
        acquired = acquire_lock_with_timeout(f, lock_timeout)

        if acquired
          log_system("container.codex_auth_lock.acquired", lockfile: lockfile)
          yield
        else
          log_system("container.codex_auth_lock.timeout",
            lockfile: lockfile,
            lock_timeout_seconds: lock_timeout)
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

      result = container.exec(
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

    def seed_gemini_credentials!
      source_files = %w[
        oauth_creds.json
        google_accounts.json
        settings.json
        installation_id
        state.json
        trustedFolders.json
        projects.json
      ]
      return unless gemini_subscription_auth?

      # Prefer the source that actually contains oauth_creds.json so we don't
      # set PAID_GEMINI_SUBSCRIPTION_AUTH=1 without seeding creds.
      host = gemini_config_host_path
      if host.present? && File.file?(File.join(host, "oauth_creds.json"))
        seed_host_credentials!(
          staging_path: "/home/agent/.gemini-host",
          target_path: "/home/agent/.gemini",
          files: source_files,
          success_log_key: "container.gemini_credentials_seeded",
          failure_log_key: "container.gemini_credentials_seed_failed"
        )
      else
        seed_local_credentials!(
          source_path: gemini_local_config_path,
          target_path: "/home/agent/.gemini",
          files: source_files,
          success_log_key: "container.gemini_credentials_seeded",
          failure_log_key: "container.gemini_credentials_seed_failed"
        )
      end
    end

    def seed_copilot_credentials!
      source_files = %w[
        config.json
        settings.json
        permissions-config.json
        mcp-config.json
        lsp-config.json
      ]
      return unless copilot_subscription_auth?

      host = copilot_config_host_path
      if host.present? && File.file?(File.join(host, "config.json"))
        seed_host_credentials!(
          staging_path: "/home/agent/.copilot-host",
          target_path: "/home/agent/.copilot",
          files: source_files,
          success_log_key: "container.copilot_credentials_seeded",
          failure_log_key: "container.copilot_credentials_seed_failed"
        )
      elsif copilot_local_config_path.present?
        seed_local_credentials!(
          source_path: copilot_local_config_path,
          target_path: "/home/agent/.copilot",
          files: source_files,
          success_log_key: "container.copilot_credentials_seeded",
          failure_log_key: "container.copilot_credentials_seed_failed"
        )
      end
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

    def seed_host_credentials!(staging_path:, target_path:, files:, success_log_key:, failure_log_key:)
      copy_commands = files.map do |filename|
        "cp #{Shellwords.escape("#{staging_path}/#{filename}")} #{Shellwords.escape("#{target_path}/#{filename}")} 2>/dev/null"
      end

      container.exec([ "chown", "-R", "agent:agent", target_path ], user: "root")
      container.exec([ "sh", "-c", "#{copy_commands.join('; ')}; true" ], user: "agent")
      log_system(success_log_key)
    rescue Docker::Error::DockerError => e
      log_system(failure_log_key, error: e.message)
    end

    def seed_local_credentials!(source_path:, target_path:, files:, success_log_key:, failure_log_key:)
      container.exec([ "chown", "-R", "agent:agent", target_path ], user: "root")

      write_commands = []
      files.each do |filename|
        source_file = File.join(source_path, filename)
        next unless File.file?(source_file)

        encoded = Base64.strict_encode64(File.binread(source_file))
        dest = Shellwords.escape(File.join(target_path, filename))
        write_commands << "echo #{Shellwords.escape(encoded)} | base64 -d > #{dest}"
      end

      if write_commands.any?
        container.exec([ "sh", "-lc", write_commands.join("; ") ], user: "agent")
        log_system(success_log_key, files_copied: write_commands.size)
      end
    rescue Docker::Error::DockerError, SystemCallError => e
      log_system(failure_log_key, error: e.message)
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
        "/home/agent/.config/kilo",
        "/home/agent/.local/share/kilo",
        "/home/agent/.config/opencode",
        "/home/agent/.local/share/opencode",
        "/home/agent/.copilot",
        "/home/agent/.aider"
      ]

      # ~/.codex gets non-recursive chown to preserve host-backed file ownership
      recursive_script = dirs.map { |d| "chown -R agent:agent #{Shellwords.escape(d)}" }.join("; ")
      script = "#{recursive_script}; chown agent:agent /home/agent/.codex"

      container.exec([ "sh", "-c", script ], user: "root")
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
      fix_aider_tmpfs_ownership!
    end

    # Ensures the bind-mounted /workspace is writable by the non-root agent user.
    # Docker bind mounts inherit host ownership which may not match the container
    # user. Running chown as root inside the container fixes this portably.
    def fix_workspace_ownership!
      container.exec(
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
      container.exec(
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
      container.exec(
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

    # Fixes ownership of the ~/.config/kilo tmpfs so the non-root agent user
    # can write to it. Tmpfs mounts are created as root-owned.
    def fix_kilocode_config_tmpfs_ownership!
      fix_tmpfs_ownership!(".config/kilo")
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

    # Fixes ownership of the ~/.aider tmpfs so the non-root agent user can
    # write to it. Tmpfs mounts are created as root-owned.
    def fix_aider_tmpfs_ownership!
      fix_tmpfs_ownership!(".aider")
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
      container.exec(
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
    def prepare_workspace!
      if host_worktree_path.present?
        raise ProvisionError, "Worktree path does not exist: #{host_worktree_path}" unless File.directory?(host_worktree_path)
      else
        @workspace_volume ||= pooled_container? ? "paid-pool-workspace-#{pool_entry.id}" : "paid-workspace-#{agent_run.id}"
        begin
          Docker::Volume.get(@workspace_volume)
        rescue Docker::Error::NotFoundError
          Docker::Volume.create(@workspace_volume, volume_options)
        end
      end
    end

    def host_worktree_path
      return nil if worktree_path.blank?
      return nil if worktree_path == options[:workspace_mount]

      worktree_path
    end

    def write_container_file(path, content)
      encoded = Base64.strict_encode64(content)
      cmd = "echo #{Shellwords.escape(encoded)} | base64 -d > #{Shellwords.escape(path)}"
      container.exec([ "sh", "-lc", cmd ], user: "agent")
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

      Docker::Volume.get(volume_name).remove
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
      labels
    end

    def create_container
      Docker::Container.create(container_config)
    end

    def start_container
      container.start
    end

    # Writable directories inside the container:
    #   /workspace          - bind mount of workspace dir (rw, for git clone and code changes)
    #   /paid-heartbeat     - bind mount of host temp dir (rw, for heartbeat file shared with watchdog)
    #   /tmp                - tmpfs (1GB, for scratch files)
    #   /home/agent/.cache  - tmpfs (512MB, for tool caches: Codex CLI, npm, etc.)
    #   /home/agent/.claude - tmpfs (256MB, for Claude CLI session/project data)
    #   /home/agent/.codex    - tmpfs (64MB, for Codex CLI config/session data)
    #   /home/agent/.gemini   - tmpfs (64MB, for Gemini CLI config/session data)
    #   /home/agent/.cursor-agent - tmpfs (64MB, for Cursor agent CLI config/session data)
    #   /home/agent/.kilocode - tmpfs (64MB, for Kilocode CLI config/session data)
    #   /home/agent/.config/opencode         - tmpfs (64MB, for OpenCode CLI config)
    #   /home/agent/.local/share/opencode    - tmpfs (64MB, for OpenCode CLI data)
    #   /home/agent/.copilot                 - tmpfs (64MB, for GitHub Copilot CLI config)
    #   /home/agent/.aider                   - tmpfs (64MB, for Aider CLI config/session data)
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
      if @workspace_volume
        binds << "#{@workspace_volume}:#{options[:workspace_mount]}:rw"
      elsif host_worktree_path.present?
        binds << "#{host_worktree_path}:#{options[:workspace_mount]}:rw"
      end

      binds << "#{heartbeat_dir_host}:#{HEARTBEAT_MOUNT_POINT}:rw" if heartbeat_dir_host

      # Mount the host's Claude config as read-only at a staging path.
      # Credentials are copied into the writable /home/agent/.claude tmpfs
      # by seed_claude_credentials! after container start.
      if claude_config_host_path.present? &&
         File.directory?(claude_config_host_path) &&
         File.file?(File.join(claude_config_host_path, ".credentials.json"))
        binds << "#{claude_config_host_path}:/home/agent/.claude-host:ro"
      end

      if codex_subscription_auth_host_mount_path.present?
        binds.concat(codex_subscription_auth_file_binds)
      end

      if gemini_config_host_path.present? &&
         File.directory?(gemini_config_host_path) &&
         File.file?(File.join(gemini_config_host_path, "oauth_creds.json")) &&
         gemini_subscription_auth?
        binds << "#{gemini_config_host_path}:/home/agent/.gemini-host:ro"
      end

      if copilot_config_host_path.present? &&
         File.directory?(copilot_config_host_path) &&
         File.file?(File.join(copilot_config_host_path, "config.json")) &&
         copilot_subscription_auth?
        binds << "#{copilot_config_host_path}:/home/agent/.copilot-host:ro"
      end

      # /tmp must be `exec` because every coding/review/rebase prompt has the
      # agent run `bundle install` as step 1, and review-goal runs additionally
      # set BUNDLE_PATH=/tmp/bundle. Bundler builds native gem extensions in
      # the gem path; mkmf's try_link verifies the produced binary with
      # File.executable?, which returns false on a noexec mount — producing
      # a misleading "compiler failed to generate an executable file" error
      # (e.g. bigdecimal extconf) even though the toolchain is fully present.
      # Docker's default tmpfs flags include noexec, so it must be overridden.
      # /home/agent/.cache needs exec because some providers (e.g. GitHub Copilot)
      # download native Node.js addons (pty.node) into ~/.cache/copilot/pkg/ at
      # runtime; dlopen() requires mmap(PROT_EXEC), which fails on a noexec mount.
      tmpfs = {
        "/tmp" => "exec,size=#{options[:tmpfs_tmp_size]},mode=1777",
        "/home/agent/.cache" => "exec,size=#{options[:tmpfs_cache_size]},mode=0755"
      }

      # Claude CLI needs to write session data, project indexes, todos, debug
      # logs, and stats under ~/.claude. A writable tmpfs lets it do so without
      # compromising the read-only rootfs. Ownership is fixed by
      # fix_workspace_ownership!-style chown after container start.
      tmpfs["/home/agent/.claude"] = "size=#{256 * 1024 * 1024},mode=0700"

      # Codex CLI stores config and session data under ~/.codex.
      # Host-backed auth/config files are mounted into this tmpfs so session
      # state stays ephemeral while OAuth refreshes can still persist.
      tmpfs["/home/agent/.codex"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Gemini CLI stores config and session data under ~/.gemini.
      # Ownership is fixed by fix_gemini_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.gemini"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Cursor agent CLI stores config and session data under ~/.cursor-agent.
      # Ownership is fixed by fix_cursor_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.cursor-agent"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Writable directories inside the container for Kilocode CLI:
      # - ~/.kilocode (plugin data)
      # - ~/.config/kilo (config.json)
      # - ~/.local/share/kilo (auth.json, kilo.db)
      # Ownership is fixed by:
      # - fix_kilocode_tmpfs_ownership! (for ~/.kilocode)
      # - fix_kilocode_config_tmpfs_ownership! (for ~/.config/kilo)
      # - fix_kilocode_data_tmpfs_ownership! (for ~/.local/share/kilo)
      # after container start.
      tmpfs["/home/agent/.kilocode"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Kilocode CLI stores config under ~/.config/kilo (config.json) and data
      # under ~/.local/share/kilo (auth.json, kilo.db).
      tmpfs["/home/agent/.config/kilo"] = "size=#{64 * 1024 * 1024},mode=0700"
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

      # Aider CLI stores config and session data under ~/.aider.
      # Ownership is fixed by fix_aider_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.aider"] = "size=#{64 * 1024 * 1024},mode=0700"

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

    # Proxy-mode API key auth uses the restricted paid_agent network.
    # Subscription auth and direct-outbound runners use paid_internal so
    # runner CLIs can reach their upstream APIs directly.
    def container_network
      network_name
    end

    def network_contract
      @network_contract ||= NetworkPolicy.contract(
        subscription_auth: subscription_auth?,
        direct_outbound: direct_outbound_runner?
      )
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
        "HOME=/home/agent"
      ]

      env.concat(run_scoped_environment(proxy_base)) if agent_run.present?

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
        AgentHarness.runner(harness_key).cli_env_overrides.map { |k, v| "#{k}=#{v}" }
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
      proxy_port = Rails.application.config.x.paid_proxy_port
      proxy_host = network_contract.restricted? ? "paid-proxy" : "web"
      "http://#{proxy_host}:#{proxy_port}"
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
      paths = [ claude_config_host_path, claude_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, ".credentials.json")) }
    end

    def gemini_subscription_auth?
      paths = [ gemini_config_host_path, gemini_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, "oauth_creds.json")) }
    end

    def codex_subscription_auth?
      codex_subscription_auth_mount.present?
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

    def resolved_run_runner_candidates
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

    def codex_subscription_auth_file_binds
      base = codex_subscription_auth_host_mount_path
      return [] unless base.present?

      [ "#{File.join(base, 'auth.json')}:/home/agent/.codex/auth.json:rw" ]
    end

    def codex_auth_lock_required?(command)
      codex_subscription_auth_host_mount_path.present? && codex_exec_command?(command)
    end

    def codex_exec_command?(command)
      parts = command.is_a?(Array) ? command : Shellwords.split(command.to_s)
      parts.first(2) == %w[codex exec]
    rescue ArgumentError
      false
    end

    def codex_auth_lockfile_path
      runner = codex_harness_provider
      lock_config = runner.respond_to?(:auth_lock_config) ? runner.auth_lock_config : nil
      base_path = lock_config&.dig(:path)&.sub(/\.lock\z/, "")
      raise TypeError, "no lock path configured" unless base_path

      host_mount = codex_subscription_auth_host_mount_path
      digest = Digest::SHA256.hexdigest(host_mount)[0, 16]
      "#{base_path}-#{digest}.lock"
    rescue TypeError
      base = lock_config&.dig(:path)&.sub(/\.lock\z/, "") || "/tmp/codex-auth"
      "#{base}-missing.lock"
    end

    def codex_harness_provider
      AgentHarness.runner(:codex)
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
      paths = [ copilot_config_host_path, copilot_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, "config.json")) }
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
      container = Docker::Container.get(hostname)
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
      container = Docker::Container.get(hostname)
      @current_container_mounts = container.info["Mounts"] || []
    rescue Docker::Error::DockerError
      @current_container_mounts = nil
    end

    def local_config_path(dirname)
      path = File.join(ENV.fetch("HOME", "/home/vscode"), dirname)
      File.directory?(path) ? path : nil
    end

    # Resolves running service container IPs for firewall rules.
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
      info = Docker::Container.get(docker_id).info
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
      NetworkPolicy.ensure_network!(network: network_name)
      log_system("container.network.ready", network: network_name, mode: network_contract.mode)
    rescue NetworkPolicy::Error => e
      raise ProvisionError, "Network setup failed: #{e.message}"
    end

    def apply_network_restrictions!
      return unless network_contract.firewall?

      NetworkPolicy.apply_firewall_rules(
        container,
        service_destinations: resolve_service_destinations
      )
      log_system("container.firewall.applied", container_id: container.id)
    rescue NetworkPolicy::Error => e
      log_system("container.firewall.failed", error: e.message)
      # Firewall failure is not fatal in development but logged as warning.
      # In production, this should be treated as a hard failure.
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
          "No output received for #{timeout_check.idle_timeout} seconds",
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

      # Fold in heartbeat activity using the same rules as the watchdog:
      # a file touched during the current exec counts as output, and the
      # startup/idle elapsed window shrinks to the heartbeat's age.
      # A fresh heartbeat also suppresses wall-clock timeout.
      heartbeat_fresh = heartbeat_age && heartbeat_age <= elapsed_since_start
      if heartbeat_fresh
        output_received = true
        elapsed_since_activity = heartbeat_age if heartbeat_age < elapsed_since_activity
      end

      # Check startup/idle before wall-clock to match the watchdog's precedence —
      # more specific timeouts take priority over the catch-all wall-clock.
      if !output_received && tc.startup_timeout && elapsed_since_activity >= tc.startup_timeout
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
      elsif output_received && tc.idle_timeout && elapsed_since_activity >= tc.idle_timeout
        raise IdleTimeoutError.new(
          "No output received for #{tc.idle_timeout} seconds",
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
                elapsed = now - ctx.last_activity_ref.call
                total_elapsed = now - ctx.started_at_ref.call
                output_received = ctx.output_received_ref.call

                # A heartbeat file touched during the current exec counts as
                # activity equivalent to stdout output, so a working-but-silent
                # agent does not trip startup/idle timeouts. A fresh heartbeat
                # also suppresses wall-clock timeout — actively working agents
                # (making tool calls) should never be killed by time limits alone.
                # Cost and token limits serve as the primary execution ceiling.
                heartbeat_fresh = heartbeat_age && heartbeat_age <= total_elapsed
                if heartbeat_fresh
                  output_received = true
                  elapsed = heartbeat_age if heartbeat_age < elapsed
                end

                reason = if !output_received && ctx.startup_timeout && elapsed >= ctx.startup_timeout
                  :startup
                elsif output_received && ctx.idle_timeout && elapsed >= ctx.idle_timeout
                  :idle
                elsif ctx.wall_clock_timeout && total_elapsed >= ctx.wall_clock_timeout && !heartbeat_fresh
                  :wall_clock
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

            begin
              ctx.container.stop(timeout: 0)
            rescue Docker::Error::DockerError => e
              log_system("container.watchdog.stop_failed", error: e.message)
            end

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
      stdout, = container.exec(
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
