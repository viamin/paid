# frozen_string_literal: true

require "docker-api"

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

    # Default resource limits (per issue #23 requirements)
    DEFAULTS = {
      memory_bytes: Integer(ENV.fetch("CONTAINER_MEMORY_BYTES", 4 * 1024 * 1024 * 1024)), # 4GB RAM
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
      @options = DEFAULTS.merge(options)
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
    # @return [Result] Result with stdout, stderr, and exit_code
    # @raise [StartupTimeoutError] when no output is received within +startup_timeout+ seconds
    # @raise [IdleTimeoutError] when output stops for more than +idle_timeout+ seconds
    # @raise [TimeoutError] when total wall-clock +timeout+ is exceeded
    def execute(command, timeout: nil, startup_timeout: nil, idle_timeout: nil, stream: true)
      raise ProvisionError, "Container not provisioned" unless container

      timeout ||= options[:timeout_seconds]
      cmd_array = command.is_a?(Array) ? command : [ "sh", "-c", command ]

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
      timeout_reason = nil # :startup or :idle, set by watchdog
      timeout_reason_ref = -> { timeout_reason }
      watchdog = nil

      begin
        watchdog = start_watchdog(
          container: container,
          watchdog_mutex: watchdog_mutex,
          output_received_ref: -> { output_received },
          last_activity_ref: -> { last_activity_at },
          exec_completed_ref: -> { exec_completed },
          timeout_reason_setter: ->(reason) { timeout_reason = reason },
          startup_timeout: startup_timeout,
          idle_timeout: idle_timeout,
          wall_clock_timeout: timeout,
          started_at_ref: -> { started_at }
        )

        exec_result = nil
        exec_result = container.exec(cmd_array, wait: timeout) do |stream_type, chunk|
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
        raise_if_watchdog_timeout!(watchdog_mutex, timeout_reason_ref, startup_timeout, idle_timeout, timeout)

        # The watchdog polls periodically, so exec may return between ticks with a
        # deadline already exceeded. Check the deadline directly in the main thread.
        check_deadline_exceeded!(
          watchdog_mutex,
          output_received,
          last_activity_at,
          started_at,
          startup_timeout,
          idle_timeout,
          timeout
        )

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
      rescue Docker::Error::DockerError => e
        # Log partial output first — raise_if_watchdog_timeout! may re-raise.
        log_partial_output(stdout_buffer, stderr_buffer)
        raise_if_watchdog_timeout!(watchdog_mutex, timeout_reason_ref, startup_timeout, idle_timeout, timeout)
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
        container.delete(force: force)
        log_system("container.cleanup.success")
      rescue Docker::Error::DockerError => e
        log_system("container.cleanup.failed", error: e.message)
        begin
          container.delete(force: true)
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
      return unless claude_config_host_path.present?

      # Fix tmpfs ownership (created as root) then copy credential files.
      container.exec(
        [ "chown", "-R", "agent:agent", "/home/agent/.claude" ],
        user: "root"
      )
      container.exec(
        [ "sh", "-c",
          "cp /home/agent/.claude-host/.credentials.json /home/agent/.claude/.credentials.json 2>/dev/null; " \
          "cp /home/agent/.claude-host/settings.json /home/agent/.claude/settings.json 2>/dev/null; " \
          "true" ],
        user: "agent"
      )
      log_system("container.claude_credentials_seeded")
    rescue Docker::Error::DockerError => e
      log_system("container.claude_credentials_seed_failed", error: e.message)
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
    #   /home/agent/.cache  - tmpfs (512MB, for tool caches)
    #   /home/agent/.claude - tmpfs (256MB, for Claude CLI session/project data)
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
      binds << "#{claude_config_host_path}:/home/agent/.claude-host:ro" if claude_config_host_path.present?

      tmpfs = {
        "/tmp" => "size=#{options[:tmpfs_tmp_size]},mode=1777",
        "/home/agent/.cache" => "size=#{options[:tmpfs_cache_size]},mode=0755"
      }

      # Claude CLI needs to write session data, project indexes, todos, debug
      # logs, and stats under ~/.claude. A writable tmpfs lets it do so without
      # compromising the read-only rootfs. Ownership is fixed by
      # fix_workspace_ownership!-style chown after container start.
      tmpfs["/home/agent/.claude"] = "size=#{256 * 1024 * 1024},mode=0700"

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
      subscription_auth? ? NetworkPolicy::INFRA_NETWORK_NAME : NetworkPolicy::NETWORK_NAME
    end

    def environment_variables
      project = agent_run.project
      proxy_port = ENV.fetch("PAID_PROXY_PORT", "3000")
      proxy_host = subscription_auth? ? "web" : "paid-proxy"
      proxy_base = "http://#{proxy_host}:#{proxy_port}"

      env = [
        "PAID_PROXY_URL=#{proxy_base}",
        "GITHUB_API_URL=#{proxy_base}/api/proxy/github",
        "PROJECT_ID=#{project.id}",
        "AGENT_RUN_ID=#{agent_run.id}",
        "PROXY_TOKEN=#{agent_run.proxy_token}",
        "HOME=/home/agent"
      ]

      if subscription_auth?
        # Subscription mode: Claude Code uses its native auth from ~/.claude/.
        # Don't override ANTHROPIC_BASE_URL — let it talk to Anthropic directly.
        log_system("container.auth_mode", mode: "subscription")
      else
        # API key mode: route LLM calls through the secrets proxy.
        env.concat([
          "ANTHROPIC_BASE_URL=#{proxy_base}/api/proxy/anthropic",
          "OPENAI_BASE_URL=#{proxy_base}/api/proxy/openai",
          "ANTHROPIC_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
          "OPENAI_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
          "ANTHROPIC_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
          "OPENAI_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}"
        ])
      end

      # Append service container environment variables (DATABASE_URL, REDIS_URL, etc.)
      if agent_run.service_environment.present?
        env.concat(agent_run.service_environment.map { |k, v| "#{k}=#{v}" })
      end

      env
    end

    # Returns true when Claude CLI config is available for
    # subscription-based authentication (e.g. from `claude login`).
    def subscription_auth?
      claude_config_host_path.present?
    end

    # Returns the Docker-host path to the Claude config directory.
    # Checks CLAUDE_CONFIG_DIR first, then auto-detects from container mounts
    # (for DooD setups where the devcontainer mounts ~/.claude from the host).
    def claude_config_host_path
      @claude_config_host_path ||= ENV["CLAUDE_CONFIG_DIR"].presence || detect_claude_config_host_path
    end

    def detect_claude_config_host_path
      hostname = Socket.gethostname
      container = Docker::Container.get(hostname)
      mounts = container.info["Mounts"] || []
      claude_mount = mounts.find { |m| m["Destination"]&.end_with?("/.claude") }
      claude_mount&.dig("Source")
    rescue Docker::Error::DockerError
      nil
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
      return if subscription_auth?

      NetworkPolicy.ensure_network!
      log_system("container.network.ready", network: NetworkPolicy::NETWORK_NAME)
    rescue NetworkPolicy::Error => e
      raise ProvisionError, "Network setup failed: #{e.message}"
    end

    def apply_network_restrictions!
      # Subscription auth containers are on the infrastructure network and need
      # outbound access to Anthropic. Firewall rules would block this.
      return if subscription_auth?

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
    # timeout_reason_ref is a lambda that reads the shared timeout_reason variable
    # under the mutex, ensuring we see the latest value rather than a stale snapshot.
    def raise_if_watchdog_timeout!(watchdog_mutex, timeout_reason_ref, startup_timeout, idle_timeout, timeout)
      reason = watchdog_mutex.synchronize { timeout_reason_ref.call }
      return unless reason

      case reason
      when :startup
        raise StartupTimeoutError, "No output received within #{startup_timeout} seconds"
      when :idle
        raise IdleTimeoutError, "No output received for #{idle_timeout} seconds"
      when :wall_clock
        log_system("container.execute.timeout", timeout_type: "wall_clock", timeout: timeout)
        raise TimeoutError, "Command timed out after #{timeout} seconds"
      end
    end

    # Post-exec deadline check for when exec returns between watchdog polling
    # ticks. The watchdog sleeps 1s between checks, so a fast-completing exec
    # can slip through with a deadline already exceeded.
    def check_deadline_exceeded!(watchdog_mutex, output_received, last_activity_at, started_at,
      startup_timeout, idle_timeout, timeout)
      return unless startup_timeout || idle_timeout || timeout

      elapsed_since_activity, elapsed_since_start = watchdog_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [ now - last_activity_at, now - started_at ]
      end

      if timeout && elapsed_since_start >= timeout
        log_system("container.execute.timeout", timeout_type: "wall_clock", timeout: timeout)
        raise TimeoutError, "Command timed out after #{timeout} seconds"
      elsif !output_received && startup_timeout && elapsed_since_activity >= startup_timeout
        raise StartupTimeoutError, "No output received within #{startup_timeout} seconds"
      elsif output_received && idle_timeout && elapsed_since_activity >= idle_timeout
        raise IdleTimeoutError, "No output received for #{idle_timeout} seconds"
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
    def start_watchdog(container:, watchdog_mutex:, output_received_ref:,
      last_activity_ref:, exec_completed_ref:, timeout_reason_setter:,
      startup_timeout:, idle_timeout:, wall_clock_timeout:, started_at_ref:)
      return nil unless startup_timeout || idle_timeout || wall_clock_timeout

      Thread.new do
        loop do
          sleep watchdog_poll_interval

          should_fire = watchdog_mutex.synchronize do
            if exec_completed_ref.call
              false
            else
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              elapsed = now - last_activity_ref.call
              total_elapsed = now - started_at_ref.call

              reason = if !output_received_ref.call && startup_timeout && elapsed >= startup_timeout
                :startup
              elsif output_received_ref.call && idle_timeout && elapsed >= idle_timeout
                :idle
              elsif wall_clock_timeout && total_elapsed >= wall_clock_timeout
                :wall_clock
              end

              if reason
                timeout_reason_setter.call(reason)
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
          break if watchdog_mutex.synchronize { exec_completed_ref.call }

          begin
            container.stop(timeout: 0)
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
