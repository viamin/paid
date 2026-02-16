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

    # Default resource limits (per issue #23 requirements)
    DEFAULTS = {
      memory_bytes: 2 * 1024 * 1024 * 1024,     # 2GB RAM
      cpu_quota: 200_000,                        # 2 CPUs (100_000 per CPU)
      pids_limit: 500,                           # 500 process limit
      timeout_seconds: 600,                      # 10 minutes default timeout
      tmpfs_tmp_size: 1024 * 1024 * 1024,        # 1GB for /tmp
      tmpfs_cache_size: 512 * 1024 * 1024,       # 512MB for /home/agent/.cache
      image: "paid-agent:latest",
      user: "agent",
      workspace_mount: "/workspace"
    }.freeze

    WORKSPACE_ROOT = ENV.fetch("WORKSPACE_ROOT", "/var/paid/workspaces")

    attr_reader :agent_run, :worktree_path, :container, :options, :workspace_dir

    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param worktree_path [String, nil] Path to an existing worktree to bind-mount.
    #   When nil, an empty per-run directory is auto-created for in-container git clone.
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
      @workspace_dir = nil
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
      apply_network_restrictions!

      log_system("container.provision.success", container_id: container.id)
      Result.success(container_id: container.id)
    rescue Docker::Error::DockerError => e
      log_system("container.provision.failed", error: e.message)
      cleanup
      raise ProvisionError, "Docker error: #{e.message}"
    rescue StandardError => e
      log_system("container.provision.failed", error: e.message)
      cleanup
      raise
    end

    # Executes a command inside the container and captures output.
    #
    # @param command [String, Array<String>] Command to execute
    # @param timeout [Integer] Timeout in seconds (default from options)
    # @param stream [Boolean] Whether to stream output to agent logs
    # @return [Result] Result with stdout, stderr, and exit_code
    def execute(command, timeout: nil, stream: true)
      raise ProvisionError, "Container not provisioned" unless container

      timeout ||= options[:timeout_seconds]
      cmd_array = command.is_a?(Array) ? command : [ "sh", "-c", command ]

      log_system("container.execute.start", command: command.to_s.encode("UTF-8", invalid: :replace).truncate(200))

      stdout_buffer = []
      stderr_buffer = []
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        exec_result = nil
        Timeout.timeout(timeout) do
          exec_result = container.exec(cmd_array) do |stream_type, chunk|
            case stream_type
            when :stdout
              stdout_buffer << chunk
              log_output(:stdout, chunk) if stream
            when :stderr
              stderr_buffer << chunk
              log_output(:stderr, chunk) if stream
            end
          end
        end

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
      rescue Timeout::Error
        # Log any accumulated output before raising so partial results aren't lost
        log_output(:stdout, stdout_buffer.join) if stdout_buffer.any?
        log_output(:stderr, stderr_buffer.join) if stderr_buffer.any?
        log_system("container.execute.timeout", timeout: timeout)
        raise TimeoutError, "Command timed out after #{timeout} seconds"
      rescue Docker::Error::DockerError => e
        # Log any accumulated output before raising so partial results aren't lost
        log_output(:stdout, stdout_buffer.join) if stdout_buffer.any?
        log_output(:stderr, stderr_buffer.join) if stderr_buffer.any?
        log_system("container.execute.failed", error: e.message)
        raise ExecutionError.new("Docker exec error: #{e.message}")
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
        cleanup_workspace_dir
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

    # Sets up the workspace directory for the container.
    # When worktree_path is provided, validates it exists (legacy bind mount).
    # When nil, creates a fresh per-run directory for in-container git clone.
    def prepare_workspace!
      if worktree_path.present?
        raise ProvisionError, "Worktree path does not exist: #{worktree_path}" unless File.directory?(worktree_path)
      else
        @workspace_dir = File.join(WORKSPACE_ROOT, "runs", agent_run.id.to_s)
        FileUtils.mkdir_p(@workspace_dir)
        @worktree_path = @workspace_dir
      end
    end

    def cleanup_workspace_dir
      return unless @workspace_dir
      return unless Dir.exist?(@workspace_dir)

      FileUtils.rm_rf(@workspace_dir)
      @workspace_dir = nil
    rescue => e
      Rails.logger.warn(
        message: "container_manager.workspace_cleanup_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    def create_container
      Docker::Container.create(container_config)
    end

    def start_container
      container.start
    end

    # Writable directories inside the container:
    #   /workspace  - bind mount of workspace dir (rw, for git clone and code changes)
    #   /tmp        - tmpfs (1GB, for scratch files)
    #   /home/agent/.cache - tmpfs (512MB, for tool caches)
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
      binds << "#{worktree_path}:#{options[:workspace_mount]}:rw" if worktree_path.present?

      # Mount the host's Claude config directory for subscription-based auth.
      # CLAUDE_CONFIG_DIR must be the Docker-host path (not the worker container path)
      # because Docker bind mounts reference the host filesystem.
      claude_config = ENV["CLAUDE_CONFIG_DIR"]
      binds << "#{claude_config}:/home/agent/.claude:ro" if claude_config.present?

      {
        "Memory" => options[:memory_bytes],
        # MemorySwap == Memory disables swap. Containers exceeding the memory
        # limit are OOM-killed immediately rather than swapping to disk.
        "MemorySwap" => options[:memory_bytes],
        "CpuPeriod" => 100_000,
        "CpuQuota" => options[:cpu_quota],
        "PidsLimit" => options[:pids_limit],
        "Tmpfs" => {
          "/tmp" => "size=#{options[:tmpfs_tmp_size]},mode=1777",
          "/home/agent/.cache" => "size=#{options[:tmpfs_cache_size]},mode=0755"
        },
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

      env
    end

    # Returns true when the host's Claude CLI config is available for
    # subscription-based authentication (e.g. from `claude login`).
    def subscription_auth?
      ENV["CLAUDE_CONFIG_DIR"].present?
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

      NetworkPolicy.apply_firewall_rules(container)
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
