# frozen_string_literal: true

require "base64"
require "docker-api"
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
      def initialize(msg = "Operation timed out")
        super
      end
    end

    # Raised when no output is received within the startup timeout
    class StartupTimeoutError < TimeoutError
      def initialize(msg = "No output received within startup timeout")
        super
      end
    end

    # Raised when output stops flowing for longer than the idle timeout
    class IdleTimeoutError < TimeoutError
      def initialize(msg = "No output received within idle timeout")
        super
      end
    end

    # Bundles watchdog shared state (mutex, refs, timeouts) into a single
    # object to keep start_watchdog's parameter list under 4.
    WatchdogContext = Struct.new(
      :container, :mutex, :output_received_ref, :last_activity_ref,
      :exec_completed_ref, :timeout_reason_setter,
      :startup_timeout, :idle_timeout, :wall_clock_timeout, :started_at_ref,
      keyword_init: true
    )

    # Bundles timeout-check state shared between raise_if_watchdog_timeout!
    # and check_deadline_exceeded! to keep their parameter lists under 4.
    TimeoutCheckState = Struct.new(
      :mutex, :timeout_reason_ref, :startup_timeout, :idle_timeout,
      :timeout, :started_at,
      keyword_init: true
    )

    # Default resource limits (per issue #23 requirements)
    DEFAULTS = {
      memory_bytes: 4 * 1024 * 1024 * 1024, # 4GB RAM default; overridden by UserSetting#container_memory_bytes
      cpu_quota: 200_000,                        # 2 CPUs (100_000 per CPU)
      pids_limit: 500,                           # 500 process limit
      timeout_seconds: 1800,                     # 30 minutes default timeout
      tmpfs_tmp_size: 1024 * 1024 * 1024,        # 1GB for /tmp
      tmpfs_cache_size: 512 * 1024 * 1024,       # 512MB for /home/agent/.cache
      image: "paid-agent:latest",
      user: "agent",
      workspace_mount: "/workspace"
    }.freeze

    attr_reader :agent_run, :worktree_path, :container, :options, :workspace_volume

    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param worktree_path [String, nil] Path to an existing worktree to bind-mount.
    #   When nil, a Docker named volume is created for in-container git clone.
    # @param options [Hash] Override default container options
    # @option options [Integer] :memory_bytes Memory limit in bytes
    # @option options [Integer] :cpu_quota CPU quota (100_000 per CPU)
    # @option options [Integer] :pids_limit Maximum number of processes
    # @option options [Integer] :timeout_seconds Default command timeout
    # @option options [String] :image Docker image to use
    def initialize(agent_run:, worktree_path: nil, **options)
      if options.key?(:network)
        Rails.logger.warn(
          message: "container_manager.container.network_option_ignored",
          agent_run_id: agent_run.id,
          hint: "The :network option is ignored; containers always use #{NetworkPolicy::NETWORK_NAME}"
        )
        options.delete(:network)
      end
      @agent_run = agent_run
      @worktree_path = worktree_path
      @workspace_volume = nil
      @options = DEFAULTS.merge(resolve_user_setting_overrides(agent_run)).merge(options)
      @container = nil
    end

    # Provisions a new container with security hardening.
    # Ensures the agent network exists before creating the container,
    # and applies firewall rules after start to restrict outbound traffic.
    #
    # @return [Result] Result object with success/failure status
    def provision
      log_system("container.provision.start", image: options[:image])

      prepare_workspace!
      ensure_network!
      @container = create_container
      start_container
      fix_workspace_ownership!
      fix_cache_tmpfs_ownership!
      fix_codex_tmpfs_ownership!
      seed_codex_credentials!
      fix_gemini_tmpfs_ownership!
      seed_gemini_credentials!
      fix_cursor_tmpfs_ownership!
      fix_kilocode_tmpfs_ownership!
      fix_opencode_config_tmpfs_ownership!
      fix_opencode_data_tmpfs_ownership!
      fix_copilot_tmpfs_ownership!
      seed_copilot_credentials!
      fix_aider_tmpfs_ownership!
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
    # @return [Result] Result with stdout, stderr, and exit_code
    # @raise [StartupTimeoutError] when no output is received within +startup_timeout+ seconds
    # @raise [IdleTimeoutError] when output stops for more than +idle_timeout+ seconds
    # @raise [TimeoutError] when total wall-clock +timeout+ is exceeded
    def execute(command, timeout: nil, startup_timeout: nil, idle_timeout: nil, stream: true, env: {})
      raise ProvisionError, "Container not provisioned" unless container

      timeout ||= options[:timeout_seconds]
      cmd_array = command.is_a?(Array) ? command : [ "sh", "-c", command ]
      exec_options = { wait: timeout }
      exec_options[:Env] = env.map { |key, value| "#{key}=#{value}" } if env.present?

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
      watchdog = nil

      timeout_check = TimeoutCheckState.new(
        mutex: watchdog_mutex,
        timeout_reason_ref: timeout_reason_ref,
        startup_timeout: startup_timeout,
        idle_timeout: idle_timeout,
        timeout: timeout,
        started_at: started_at
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
        started_at_ref: -> { started_at }
      )

      begin
        watchdog = start_watchdog(watchdog_ctx)

        exec_result = container.exec(cmd_array, exec_options) do |stream_type, chunk|
          watchdog_mutex.synchronize do
            output_received = true
            last_activity_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          case stream_type
          when :stdout
            stdout_buffer << chunk
            log_output(:stdout, chunk) if stream
          when :stderr
            stderr_buffer << chunk
            log_output(:stderr, chunk) if stream
          end
        end

        # Signal the watchdog that exec has returned, then stop it immediately
        # to prevent late/false timeouts during post-processing.
        watchdog_mutex.synchronize { exec_completed = true }
        stop_watchdog(watchdog)

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
      rescue StartupTimeoutError, IdleTimeoutError => e
        log_partial_output(stdout_buffer, stderr_buffer)
        timeout_value = e.is_a?(StartupTimeoutError) ? startup_timeout : idle_timeout
        log_system("container.execute.timeout", timeout_type: e.class.name.demodulize, timeout: timeout_value)
        raise
      rescue TimeoutError
        log_partial_output(stdout_buffer, stderr_buffer)
        raise
      rescue Docker::Error::DockerError => e
        # Log partial output first — raise_if_watchdog_timeout! may re-raise.
        log_partial_output(stdout_buffer, stderr_buffer)
        begin
          raise_if_watchdog_timeout!(timeout_check)
        rescue StartupTimeoutError, IdleTimeoutError => timeout_error
          timeout_value = timeout_error.is_a?(StartupTimeoutError) ? startup_timeout : idle_timeout
          log_system(
            "container.execute.timeout",
            timeout_type: timeout_error.class.name.demodulize,
            timeout: timeout_value
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
            timeout: timeout_value
          )
          raise
        end

        log_system("container.execute.failed", error: e.message)
        raise ExecutionError.new("Docker exec error: #{e.message}")
      ensure
        watchdog_mutex.synchronize { exec_completed = true }
        stop_watchdog(watchdog)
      end
    end

    # Stops and removes the container, cleaning up resources.
    #
    # @param force [Boolean] Force kill if container doesn't stop gracefully
    # @return [void]
    def cleanup(force: false)
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

    # Attaches an existing Docker container to this service instance.
    # Used by .reconnect to rehydrate container state without reaching into ivars.
    #
    # @param container [Docker::Container] The existing container
    # @return [self]
    def with_existing_container(container)
      @container = container
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
    def self.reconnect(agent_run:, container_id:, worktree_path: nil)
      container = Docker::Container.get(container_id)
      new(agent_run: agent_run, worktree_path: worktree_path).with_existing_container(container)
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

    # Resolves user-configurable container settings from the project's UserSetting.
    # Returns a hash of overrides that sit between DEFAULTS and caller-supplied options.
    def resolve_user_setting_overrides(agent_run)
      settings = AgentRuns::UserSettingsResolver.call(
        project: agent_run.project, strict: false
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
    # provider configuration.
    def seed_codex_config!
      content = <<~TOML
        model_provider = "paid"

        [model_providers.paid]
        name = "Paid"
        base_url = "#{proxy_base_url}/api/proxy/openai"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"
      TOML

      write_container_file("/home/agent/.codex/config.toml", content)
      log_system("container.codex_config_seeded")
    rescue Docker::Error::DockerError => e
      log_system("container.codex_config_seed_failed", error: e.message)
    end

    def seed_codex_credentials!
      source_files = %w[auth.json config.toml]

      unless codex_subscription_auth?
        seed_codex_config!
        return
      end

      # Prefer the source that actually contains auth.json so we don't set
      # PAID_CODEX_SUBSCRIPTION_AUTH=1 without seeding creds.
      host = codex_config_host_path
      if host.present? && File.file?(File.join(host, "auth.json"))
        seed_host_credentials!(
          staging_path: "/home/agent/.codex-host",
          target_path: "/home/agent/.codex",
          files: source_files,
          success_log_key: "container.codex_credentials_seeded",
          failure_log_key: "container.codex_credentials_seed_failed"
        )
      elsif codex_local_config_path.present?
        seed_local_credentials!(
          source_path: codex_local_config_path,
          target_path: "/home/agent/.codex",
          files: source_files,
          success_log_key: "container.codex_credentials_seeded",
          failure_log_key: "container.codex_credentials_seed_failed"
        )
      end
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
      source_files = %w[hosts.json apps.json]
      return unless copilot_subscription_auth?

      host = copilot_config_host_path
      if host.present? && File.file?(File.join(host, "hosts.json"))
        seed_host_credentials!(
          staging_path: "/home/agent/.config/github-copilot-host",
          target_path: "/home/agent/.config/github-copilot",
          files: source_files,
          success_log_key: "container.copilot_credentials_seeded",
          failure_log_key: "container.copilot_credentials_seed_failed"
        )
      elsif copilot_local_config_path.present?
        seed_local_credentials!(
          source_path: copilot_local_config_path,
          target_path: "/home/agent/.config/github-copilot",
          files: source_files,
          success_log_key: "container.copilot_credentials_seeded",
          failure_log_key: "container.copilot_credentials_seed_failed"
        )
      end
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

      copied = 0
      files.each do |filename|
        source_file = File.join(source_path, filename)
        next unless File.file?(source_file)

        write_container_file(File.join(target_path, filename), File.binread(source_file))
        copied += 1
      end

      log_system(success_log_key, files_copied: copied) if copied > 0
    rescue Docker::Error::DockerError, SystemCallError => e
      log_system(failure_log_key, error: e.message)
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
    # write to it. Tmpfs mounts are created as root-owned; this mirrors the
    # pattern used by seed_claude_credentials! for ~/.claude.
    def fix_codex_tmpfs_ownership!
      fix_tmpfs_ownership!(".codex")
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

    # Fixes ownership of the ~/.config/github-copilot tmpfs so the non-root
    # agent user can write to it. Tmpfs mounts are created as root-owned.
    def fix_copilot_tmpfs_ownership!
      fix_tmpfs_ownership!(".config/github-copilot", log_key: "config_github_copilot")
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
    # When worktree_path is provided, validates it exists (bind mount from host).
    # When nil, creates a Docker named volume for in-container git clone.
    # Docker volumes live on the overlay2 disk, bypassing the VM root filesystem.
    def prepare_workspace!
      if worktree_path.present?
        raise ProvisionError, "Worktree path does not exist: #{worktree_path}" unless File.directory?(worktree_path)
      else
        @workspace_volume = "paid-workspace-#{agent_run.id}"
        begin
          Docker::Volume.get(@workspace_volume)
        rescue Docker::Error::NotFoundError
          Docker::Volume.create(@workspace_volume, volume_options)
        end
      end
    end

    def write_container_file(path, content)
      encoded = Base64.strict_encode64(content)
      cmd = "echo #{Shellwords.escape(encoded)} | base64 -d > #{Shellwords.escape(path)}"
      container.exec([ "sh", "-lc", cmd ], user: "agent")
    end

    def cleanup_workspace_volume
      volume_name = @workspace_volume
      volume_name ||= "paid-workspace-#{agent_run.id}" if worktree_path.blank?
      return unless volume_name

      Docker::Volume.get(volume_name).remove
    rescue Docker::Error::NotFoundError
      # Volume already removed
    rescue => e
      Rails.logger.warn(
        message: "container_manager.workspace_cleanup_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    ensure
      @workspace_volume = nil
    end

    def volume_options
      {
        "Labels" => {
          "paid.managed" => "true",
          "paid.resource" => "workspace_volume",
          "paid.agent_run_id" => agent_run.id.to_s,
          "paid.project_id" => agent_run.project_id.to_s
        }
      }
    end

    def create_container
      Docker::Container.create(container_config)
    end

    def start_container
      container.start
    end

    # Writable directories inside the container:
    #   /workspace          - bind mount of workspace dir (rw, for git clone and code changes)
    #   /tmp                - tmpfs (1GB, for scratch files)
    #   /home/agent/.cache  - tmpfs (512MB, for tool caches: Codex CLI, npm, etc.)
    #   /home/agent/.claude - tmpfs (256MB, for Claude CLI session/project data)
    #   /home/agent/.codex    - tmpfs (64MB, for Codex CLI config/session data)
    #   /home/agent/.gemini   - tmpfs (64MB, for Gemini CLI config/session data)
    #   /home/agent/.cursor-agent - tmpfs (64MB, for Cursor agent CLI config/session data)
    #   /home/agent/.kilocode - tmpfs (64MB, for Kilocode CLI config/session data)
    #   /home/agent/.config/opencode         - tmpfs (64MB, for OpenCode CLI config)
    #   /home/agent/.local/share/opencode    - tmpfs (64MB, for OpenCode CLI data)
    #   /home/agent/.config/github-copilot   - tmpfs (64MB, for GitHub Copilot CLI config)
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
        "Labels" => {
          "paid.agent_run_id" => agent_run.id.to_s,
          "paid.project_id" => agent_run.project_id.to_s
        },
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
      elsif worktree_path.present?
        binds << "#{worktree_path}:#{options[:workspace_mount]}:rw"
      end

      # Mount the host's Claude config as read-only at a staging path.
      # Credentials are copied into the writable /home/agent/.claude tmpfs
      # by seed_claude_credentials! after container start.
      if claude_config_host_path.present? &&
         File.directory?(claude_config_host_path) &&
         File.file?(File.join(claude_config_host_path, ".credentials.json"))
        binds << "#{claude_config_host_path}:/home/agent/.claude-host:ro"
      end

      if codex_config_host_path.present? &&
         File.directory?(codex_config_host_path) &&
         File.file?(File.join(codex_config_host_path, "auth.json")) &&
         codex_subscription_auth?
        binds << "#{codex_config_host_path}:/home/agent/.codex-host:ro"
      end

      if gemini_config_host_path.present? &&
         File.directory?(gemini_config_host_path) &&
         File.file?(File.join(gemini_config_host_path, "oauth_creds.json")) &&
         gemini_subscription_auth?
        binds << "#{gemini_config_host_path}:/home/agent/.gemini-host:ro"
      end

      if copilot_config_host_path.present? &&
         File.directory?(copilot_config_host_path) &&
         File.file?(File.join(copilot_config_host_path, "hosts.json")) &&
         copilot_subscription_auth?
        binds << "#{copilot_config_host_path}:/home/agent/.config/github-copilot-host:ro"
      end

      tmpfs = {
        "/tmp" => "size=#{options[:tmpfs_tmp_size]},mode=1777",
        "/home/agent/.cache" => "size=#{options[:tmpfs_cache_size]},mode=0755"
      }

      # Claude CLI needs to write session data, project indexes, todos, debug
      # logs, and stats under ~/.claude. A writable tmpfs lets it do so without
      # compromising the read-only rootfs. Ownership is fixed by
      # fix_workspace_ownership!-style chown after container start.
      tmpfs["/home/agent/.claude"] = "size=#{256 * 1024 * 1024},mode=0700"

      # Codex CLI stores config and session data under ~/.codex.
      # Ownership is fixed by fix_codex_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.codex"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Gemini CLI stores config and session data under ~/.gemini.
      # Ownership is fixed by fix_gemini_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.gemini"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Cursor agent CLI stores config and session data under ~/.cursor-agent.
      # Ownership is fixed by fix_cursor_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.cursor-agent"] = "size=#{64 * 1024 * 1024},mode=0700"

      # Kilocode CLI stores config and session data under ~/.kilocode.
      # Ownership is fixed by fix_kilocode_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.kilocode"] = "size=#{64 * 1024 * 1024},mode=0700"

      # OpenCode CLI stores config under ~/.config/opencode and data under
      # ~/.local/share/opencode. Ownership is fixed by
      # fix_opencode_config_tmpfs_ownership! and fix_opencode_data_tmpfs_ownership!
      # after container start.
      tmpfs["/home/agent/.config/opencode"] = "size=#{64 * 1024 * 1024},mode=0700"
      tmpfs["/home/agent/.local/share/opencode"] = "size=#{64 * 1024 * 1024},mode=0700"

      # GitHub Copilot CLI stores config under ~/.config/github-copilot.
      # Ownership is fixed by fix_copilot_tmpfs_ownership! after container start.
      tmpfs["/home/agent/.config/github-copilot"] = "size=#{64 * 1024 * 1024},mode=0700"

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

    # Subscription auth requires outbound HTTPS to reach Anthropic's servers.
    # The paid_agent network is internal-only and blocks this, so subscription
    # mode uses the infrastructure network which has outbound routing.
    # API key mode continues to use the restricted paid_agent network.
    def container_network
      direct_outbound_provider? || subscription_auth? ? NetworkPolicy::INFRA_NETWORK_NAME : NetworkPolicy::NETWORK_NAME
    end

    def direct_outbound_provider?
      return @direct_outbound_provider if instance_variable_defined?(:@direct_outbound_provider)

      @direct_outbound_provider = compute_direct_outbound_provider?
    end

    def compute_direct_outbound_provider?
      return true if agent_run.agent_type.to_s == "kilocode"
      return true if agent_run.provider&.requires_direct_outbound?

      settings = resolved_user_settings
      return false unless settings&.fallback_enabled?

      fallback_providers_require_direct_outbound?(settings)
    end

    def fallback_providers_require_direct_outbound?(settings)
      primary_identifier = agent_run.provider&.routing_key || settings.default_provider_identifier
      fallback_identifiers = settings.fallback_priority_for(primary_provider: primary_identifier, identifiers: true)
      fallback_providers_by_id = settings.user.providers.where(
        id: fallback_identifiers.filter_map { |identifier| Provider.id_from_routing_key(identifier) }
      ).index_by(&:id)

      fallback_identifiers.any? do |identifier|
        provider_id = Provider.id_from_routing_key(identifier)
        provider = provider_id && fallback_providers_by_id[provider_id]

        next true if identifier.to_s == "kilocode" || provider&.provider_key == "kilocode"

        provider&.requires_direct_outbound?
      end
    end

    def resolved_user_settings
      @resolved_user_settings ||= AgentRuns::UserSettingsResolver.call(project: agent_run.project, strict: false)
    end

    def environment_variables
      project = agent_run.project
      proxy_base = proxy_base_url

      env = [
        "PAID_PROXY_URL=#{proxy_base}",
        "GITHUB_API_URL=#{proxy_base}/api/proxy/github",
        "PROJECT_ID=#{project.id}",
        "AGENT_RUN_ID=#{agent_run.id}",
        "PROXY_TOKEN=#{agent_run.proxy_token}",
        "HOME=/home/agent"
      ]

      env.concat([
        "OPENAI_BASE_URL=#{proxy_base}/api/proxy/openai",
        "OPENAI_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
        "OPENAI_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
        "OPENAI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}",
        "PAID_CODEX_SUBSCRIPTION_AUTH=#{codex_subscription_auth? ? 1 : 0}"
      ])

      env.concat([
        "GOOGLE_GEMINI_BASE_URL=#{proxy_base}/api/proxy/google",
        "GOOGLE_GENAI_BASE_URL=#{proxy_base}/api/proxy/google",
        "GOOGLE_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
        "GOOGLE_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
        "GEMINI_CLI_CUSTOM_HEADERS=X-Agent-Run-Id: #{agent_run.id}, X-Proxy-Token: #{agent_run.proxy_token}",
        "GEMINI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}",
        "GEMINI_SANDBOX=false",
        "GEMINI_CLI_DISABLE_RETRIES=true",
        "PAID_GEMINI_SUBSCRIPTION_AUTH=#{gemini_subscription_auth? ? 1 : 0}"
      ])

      env << "PAID_COPILOT_SUBSCRIPTION_AUTH=#{copilot_subscription_auth? ? 1 : 0}"

      env << "PAID_CLAUDE_SUBSCRIPTION_AUTH=#{claude_subscription_auth? ? 1 : 0}"

      if claude_subscription_auth?
        # Claude subscription mode: let Claude Code use its native auth from
        # ~/.claude while other providers can still use proxy credentials.
        log_system("container.auth_mode", mode: "subscription")
      else
        # Route Anthropic calls through the secrets proxy when Claude host auth
        # is not available, even if other providers have subscription auth.
        env.concat([
          "ANTHROPIC_BASE_URL=#{proxy_base}/api/proxy/anthropic",
          "ANTHROPIC_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
          "ANTHROPIC_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}"
        ])
      end

      # Append service container environment variables (DATABASE_URL, REDIS_URL, etc.)
      if agent_run.service_environment.present?
        env.concat(agent_run.service_environment.map { |k, v| "#{k}=#{v}" })
      end

      env
    end

    # Returns true when any provider CLI config is available for
    # subscription-based authentication via copied host login state.
    def subscription_auth?
      claude_subscription_auth? || codex_subscription_auth? || gemini_subscription_auth? || copilot_subscription_auth?
    end

    def proxy_base_url
      proxy_port = Rails.application.config.x.paid_proxy_port
      proxy_host = subscription_auth? || direct_outbound_provider? ? "web" : "paid-proxy"
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
      @codex_config_host_path ||= ENV["CODEX_CONFIG_DIR"].presence || ENV["CODEX_HOME"].presence || detect_host_config_path("/.codex")
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
      paths = [ codex_config_host_path, codex_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, "auth.json")) }
    end

    def copilot_config_host_path
      @copilot_config_host_path ||= ENV["COPILOT_CONFIG_DIR"].presence || detect_host_config_path("/.config/github-copilot")
    end

    def copilot_local_config_path
      @copilot_local_config_path ||= local_config_path(".config/github-copilot")
    end

    def copilot_subscription_auth?
      paths = [ copilot_config_host_path, copilot_local_config_path ].compact
      paths.any? { |base| File.file?(File.join(base, "hosts.json")) }
    end

    def detect_host_config_path(suffix)
      hostname = Socket.gethostname
      container = Docker::Container.get(hostname)
      mounts = container.info["Mounts"] || []
      config_mount = mounts.find { |mount| mount["Destination"]&.end_with?(suffix) }
      config_mount&.dig("Source")
    rescue Docker::Error::DockerError
      nil
    end

    def local_config_path(dirname)
      path = File.join(ENV.fetch("HOME", "/home/vscode"), dirname)
      File.directory?(path) ? path : nil
    end

    # Resolves running service container IPs for firewall rules.
    def resolve_service_destinations
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
      "paid-#{agent_run.project_id}-#{agent_run.id}-#{SecureRandom.hex(4)}"
    end

    def ensure_network!
      # Subscription auth uses the infrastructure network (already managed by compose).
      # Only the restricted agent network needs explicit creation.
      return if subscription_auth? || direct_outbound_provider?

      NetworkPolicy.ensure_network!
      log_system("container.network.ready", network: NetworkPolicy::NETWORK_NAME)
    rescue NetworkPolicy::Error => e
      raise ProvisionError, "Network setup failed: #{e.message}"
    end

    def apply_network_restrictions!
      # Subscription auth containers are on the infrastructure network and need
      # outbound access to Anthropic. Firewall rules would block this.
      return if subscription_auth? || direct_outbound_provider?

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

    def log_system(message, **metadata)
      Rails.logger.info(
        message: "container_manager.#{message}",
        agent_run_id: agent_run.id,
        **metadata
      )

      agent_run.log!("system", message, metadata: metadata)
    end

    def log_output(type, content)
      return if content.blank?

      agent_run.log!(type.to_s, content)
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
        raise StartupTimeoutError, "No output received within #{timeout_check.startup_timeout} seconds"
      when :idle
        raise IdleTimeoutError, "No output received for #{timeout_check.idle_timeout} seconds"
      when :wall_clock
        log_system("container.execute.timeout", timeout_type: "wall_clock", timeout: timeout_check.timeout)
        raise TimeoutError, "Command timed out after #{timeout_check.timeout} seconds"
      end
    end

    # Post-exec deadline check for when exec returns between watchdog polling
    # ticks. The watchdog sleeps 1s between checks, so a fast-completing exec
    # can slip through with a deadline already exceeded.
    def check_deadline_exceeded!(timeout_check, output_received:, last_activity_at:)
      tc = timeout_check
      return unless tc.startup_timeout || tc.idle_timeout || tc.timeout

      elapsed_since_activity, elapsed_since_start = tc.mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [ now - last_activity_at, now - tc.started_at ]
      end

      # Check startup/idle before wall-clock to match the watchdog's precedence —
      # more specific timeouts take priority over the catch-all wall-clock.
      if !output_received && tc.startup_timeout && elapsed_since_activity >= tc.startup_timeout
        raise StartupTimeoutError, "No output received within #{tc.startup_timeout} seconds"
      elsif output_received && tc.idle_timeout && elapsed_since_activity >= tc.idle_timeout
        raise IdleTimeoutError, "No output received for #{tc.idle_timeout} seconds"
      elsif tc.timeout && elapsed_since_start >= tc.timeout
        log_system("container.execute.timeout", timeout_type: "wall_clock", timeout: tc.timeout)
        raise TimeoutError, "Command timed out after #{tc.timeout} seconds"
      end
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
          sleep watchdog_poll_interval

          should_fire = ctx.mutex.synchronize do
            if ctx.exec_completed_ref.call
              false
            else
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              elapsed = now - ctx.last_activity_ref.call
              total_elapsed = now - ctx.started_at_ref.call

              reason = if !ctx.output_received_ref.call && ctx.startup_timeout && elapsed >= ctx.startup_timeout
                :startup
              elsif ctx.output_received_ref.call && ctx.idle_timeout && elapsed >= ctx.idle_timeout
                :idle
              elsif ctx.wall_clock_timeout && total_elapsed >= ctx.wall_clock_timeout
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
        end
      end
    end

    # How often the watchdog thread checks for timeouts, in seconds.
    # Extracted as a method so tests can override with a shorter interval.
    def watchdog_poll_interval
      1
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
