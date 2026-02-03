# frozen_string_literal: true

require "docker-api"

module Containers
  # Service for provisioning, managing, and cleaning up Docker containers for agent execution.
  #
  # @example Basic usage
  #   service = Containers::Provision.new(
  #     agent_run: agent_run,
  #     worktree_path: "/var/paid/workspaces/123/456"
  #   )
  #   result = service.provision
  #   if result.success?
  #     service.execute("claude --version")
  #   end
  #   service.cleanup
  #
  # @example With block for automatic cleanup
  #   Containers::Provision.with_container(agent_run: agent_run, worktree_path: path) do |container|
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
      image: "paid-agent:latest",
      network: "paid_agent_network",
      user: "agent",
      workspace_mount: "/workspace"
    }.freeze

    attr_reader :agent_run, :worktree_path, :container, :options

    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param worktree_path [String] Path to the git worktree to mount
    # @param options [Hash] Override default container options
    # @option options [Integer] :memory_bytes Memory limit in bytes
    # @option options [Integer] :cpu_quota CPU quota (100_000 per CPU)
    # @option options [Integer] :pids_limit Maximum number of processes
    # @option options [Integer] :timeout_seconds Default command timeout
    # @option options [String] :image Docker image to use
    # @option options [String] :network Docker network to attach to
    def initialize(agent_run:, worktree_path:, **options)
      @agent_run = agent_run
      @worktree_path = worktree_path
      @options = DEFAULTS.merge(options)
      @container = nil
    end

    # Provisions a new container with security hardening.
    #
    # @return [Result] Result object with success/failure status
    def provision
      log_system("container.provision.start", image: options[:image])

      validate_worktree_path!
      @container = create_container
      start_container

      log_system("container.provision.success", container_id: container.id)
      Result.success(container_id: container.id)
    rescue Docker::Error::DockerError => e
      log_system("container.provision.failed", error: e.message)
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

      log_system("container.execute.start", command: command.to_s.truncate(200))

      stdout_buffer = []
      stderr_buffer = []

      begin
        Timeout.timeout(timeout) do
          container.exec(cmd_array, wait: timeout) do |stream_type, chunk|
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

        # Get exit code from last exec
        exit_code = fetch_exit_code

        stdout = stdout_buffer.join
        stderr = stderr_buffer.join

        log_system("container.execute.complete", exit_code: exit_code, duration_ms: 0)

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
        log_system("container.execute.timeout", timeout: timeout)
        raise TimeoutError, "Command timed out after #{timeout} seconds"
      rescue Docker::Error::DockerError => e
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
        if container_running?
          container.stop(timeout: force ? 0 : 10)
        end
        container.delete(force: force)
        log_system("container.cleanup.success")
      rescue Docker::Error::DockerError => e
        log_system("container.cleanup.failed", error: e.message)
        # Try force cleanup if graceful cleanup failed
        begin
          container.delete(force: true)
        rescue Docker::Error::DockerError
          # Container may already be gone
        end
      ensure
        @container = nil
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

    # Provisions a container, yields to block, then ensures cleanup.
    #
    # @param agent_run [AgentRun] The agent run to associate logs with
    # @param worktree_path [String] Path to the git worktree to mount
    # @param options [Hash] Override default container options
    # @yield [Provision] The provisioned container service instance
    # @return [Object] The return value of the block
    def self.with_container(agent_run:, worktree_path:, **options)
      service = new(agent_run: agent_run, worktree_path: worktree_path, **options)
      service.provision
      yield service
    ensure
      service&.cleanup
    end

    private

    def validate_worktree_path!
      raise ProvisionError, "Worktree path is required" if worktree_path.blank?
      raise ProvisionError, "Worktree path does not exist: #{worktree_path}" unless File.directory?(worktree_path)
    end

    def create_container
      Docker::Container.create(container_config)
    end

    def start_container
      container.start
    end

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
        "Tty" => false,
        "OpenStdin" => false
      }
    end

    def host_config
      config = {
        "Memory" => options[:memory_bytes],
        "MemorySwap" => options[:memory_bytes],
        "CpuQuota" => options[:cpu_quota],
        "PidsLimit" => options[:pids_limit],
        "Tmpfs" => {
          "/tmp" => "size=1073741824,mode=1777",
          "/home/agent/.cache" => "size=536870912,mode=0755"
        },
        "Binds" => [ "#{worktree_path}:#{options[:workspace_mount]}:rw" ]
      }

      # Only add network mode if network exists
      config["NetworkMode"] = options[:network] if network_exists?(options[:network])

      config
    end

    def environment_variables
      project = agent_run.project

      [
        "PAID_PROXY_URL=http://paid-proxy:3001",
        "PROJECT_ID=#{project.id}",
        "AGENT_RUN_ID=#{agent_run.id}",
        "HOME=/home/agent",
        "ANTHROPIC_BASE_URL=http://paid-proxy:3001/proxy/api.anthropic.com",
        "OPENAI_BASE_URL=http://paid-proxy:3001/proxy/api.openai.com"
      ]
    end

    def container_name
      "paid-#{agent_run.project_id}-#{agent_run.id}-#{SecureRandom.hex(4)}"
    end

    def network_exists?(network_name)
      Docker::Network.get(network_name)
      true
    rescue Docker::Error::NotFoundError
      false
    end

    def fetch_exit_code
      container.refresh!
      container.info.dig("State", "ExitCode") || 0
    rescue Docker::Error::DockerError
      -1
    end

    def log_system(message, **metadata)
      return unless agent_run

      Rails.logger.info(
        message: "container_manager.#{message}",
        agent_run_id: agent_run.id,
        **metadata
      )

      agent_run.log!("system", message, metadata: metadata)
    end

    def log_output(type, content)
      return unless agent_run
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
