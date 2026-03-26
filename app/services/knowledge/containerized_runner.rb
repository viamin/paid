# frozen_string_literal: true

require "docker-api"
require "open3"
require "fileutils"
require "timeout"

module Knowledge
  # Runs knowledge collectors inside an isolated Docker container.
  #
  # Clones the repo on the host, then provisions a lightweight container
  # (paid-agent:latest) with the repo bind-mounted read-only. Runs each
  # registered collector inside the container and extracts results.
  # No API keys or secrets are exposed — collectors are read-only analysis.
  #
  # @example
  #   Knowledge::ContainerizedRunner.call(
  #     project: project,
  #     commit_sha: "abc123",
  #     branch: "main"
  #   )
  class ContainerizedRunner
    class Error < StandardError; end
    class ContainerError < Error; end
    class CloneError < Error; end
    class TimeoutError < ContainerError; end

    # Lightweight resource limits — collectors don't need 4GB of memory.
    CONTAINER_DEFAULTS = {
      image: "paid-agent:latest",
      memory_bytes: 512 * 1024 * 1024,  # 512MB
      cpu_quota: 100_000,                # 1 CPU
      pids_limit: 200,
      timeout_seconds: 300,              # 5 minutes
      workspace_mount: "/workspace"
    }.freeze

    COMMIT_SHA_PATTERN = /\A[0-9a-f]{40}\z/i
    PROJECT_NAME_PATTERN = %r{\A[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+\z}

    attr_reader :project, :commit_sha, :branch, :committed_at, :options, :host_repo_dir

    def initialize(project:, commit_sha:, branch: "main", committed_at: nil, options: {})
      @project = project
      @commit_sha = commit_sha
      @branch = branch
      @committed_at = committed_at
      @options = CONTAINER_DEFAULTS.merge(options)
      @container = nil
      @host_repo_dir = nil
    end

    def self.call(...)
      new(...).run
    end

    # Returns true when Docker is available and containerized execution is possible.
    def self.available?
      return false if ENV["COLLECTORS_USE_HOST"] == "true"

      Docker.ping == "OK"
    rescue Excon::Error, Docker::Error::DockerError
      false
    end

    def run
      clone_repo_on_host!
      provision_container!

      Knowledge::CollectorRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at,
        options: { container_runner: self }
      )
    ensure
      cleanup!
    end

    # Executes a command inside the collector container and returns stdout.
    # Uses a watchdog thread that stops the container to unblock a stuck exec
    # stream — matching the pattern in Containers::Provision#execute.
    #
    # @param command [String, Array<String>] Command to execute
    # @param timeout [Integer] Timeout in seconds
    # @return [String] stdout output
    # @raise [ContainerError] when command fails
    # @raise [TimeoutError] when command exceeds timeout
    def execute(command, timeout: nil)
      raise ContainerError, "Container not provisioned" unless @container

      timeout ||= options[:timeout_seconds]
      cmd_array = command.is_a?(Array) ? command : [ "sh", "-c", command ]

      mutex = Mutex.new
      exec_completed = false
      timed_out = false

      watchdog = start_exec_watchdog(timeout, mutex) do
        mutex.synchronize do
          unless exec_completed
            timed_out = true
            true
          end
        end
      end

      begin
        result = @container.exec(cmd_array, wait: timeout)
      rescue Docker::Error::DockerError => e
        raise TimeoutError, "Command timed out after #{timeout} seconds" if mutex.synchronize { timed_out }
        raise ContainerError, "Command execution failed: #{e.message}"
      ensure
        mutex.synchronize { exec_completed = true }
        stop_watchdog(watchdog)
      end

      raise TimeoutError, "Command timed out after #{timeout} seconds" if mutex.synchronize { timed_out }

      stdout = Array(result[0]).join
      stderr = Array(result[1]).join
      exit_code = result[2]

      unless exit_code == 0
        raise ContainerError,
          "Command failed (exit #{exit_code}): #{stderr.first(500)}"
      end

      stdout
    end

    private

    def clone_repo_on_host!
      validate_commit_sha!(commit_sha)
      validate_project_name!(project.full_name)

      log("containerized_runner.clone.start", commit_sha: commit_sha)

      @host_repo_dir = Dir.mktmpdir("paid-collector-")
      url = "https://github.com/#{project.full_name}.git"

      run_host_git("init", @host_repo_dir)
      run_host_git("-C", @host_repo_dir, "remote", "add", "origin", url)
      run_host_git("-C", @host_repo_dir, "fetch", "--depth", "1", "origin", commit_sha, timeout: 120)
      run_host_git("-C", @host_repo_dir, "checkout", "FETCH_HEAD")

      # Ensure the container's agent user can read the bind-mounted directory.
      FileUtils.chmod(0o755, @host_repo_dir)

      log("containerized_runner.clone.success")
    rescue Error
      raise
    rescue => e
      cleanup_host_repo!
      raise CloneError, "Failed to clone repo: #{e.message}"
    end

    def provision_container!
      log("containerized_runner.provision.start")

      @container = Docker::Container.create(container_config)
      @container.start

      log("containerized_runner.provision.success", container_id: @container.id)
    rescue Docker::Error::DockerError => e
      cleanup!
      raise ContainerError, "Failed to provision collector container: #{e.message}"
    end

    def container_config
      {
        "Image" => options[:image],
        "name" => container_name,
        "User" => "agent",
        "ReadonlyRootfs" => true,
        "CapDrop" => [ "ALL" ],
        "SecurityOpt" => [ "no-new-privileges:true" ],
        "HostConfig" => host_config,
        "Env" => environment_variables,
        "WorkingDir" => options[:workspace_mount],
        "Labels" => {
          "paid.resource" => "collector_container",
          "paid.project_id" => project.id.to_s
        },
        "Tty" => false,
        "OpenStdin" => false,
        "Cmd" => [ "tail", "-f", "/dev/null" ]
      }
    end

    def host_config
      {
        "Memory" => options[:memory_bytes],
        "MemorySwap" => options[:memory_bytes],
        "CpuPeriod" => 100_000,
        "CpuQuota" => options[:cpu_quota],
        "PidsLimit" => options[:pids_limit],
        "Tmpfs" => {
          "/tmp" => "size=#{256 * 1024 * 1024},mode=1777",
          "/home/agent/.cache" => "size=#{128 * 1024 * 1024},mode=0755"
        },
        "Binds" => [
          "#{@host_repo_dir}:#{options[:workspace_mount]}:ro"
        ],
        "NetworkMode" => "none"
      }
    end

    # No API keys, no proxy URLs — collectors are read-only analysis.
    def environment_variables
      [
        "HOME=/home/agent",
        "PROJECT_ID=#{project.id}"
      ]
    end

    def container_name
      "paid-collector-#{project.id}-#{SecureRandom.hex(4)}"
    end

    def validate_commit_sha!(sha)
      return if COMMIT_SHA_PATTERN.match?(sha.to_s)

      raise CloneError, "Invalid commit SHA: #{sha.inspect}"
    end

    def validate_project_name!(name)
      return if PROJECT_NAME_PATTERN.match?(name.to_s)

      raise CloneError, "Invalid project name: #{name.inspect}"
    end

    def run_host_git(*args, timeout: 30)
      stdout, stderr, status = nil
      Timeout.timeout(timeout) do
        stdout, stderr, status = Open3.capture3("git", *args)
      end
      unless status.success?
        raise CloneError, "git #{args.first} failed: #{stderr.first(500)}"
      end
      stdout
    end

    # Starts a watchdog thread that stops the container to unblock a stuck exec
    # stream after the timeout elapses — matching the pattern in
    # Containers::Provision#execute.
    def start_exec_watchdog(timeout, mutex)
      return nil unless timeout

      Thread.new do
        sleep(timeout)
        should_stop = yield
        next unless should_stop

        begin
          @container&.stop(timeout: 0)
        rescue Docker::Error::DockerError
          # Container may already be stopped
        end
      end
    end

    def stop_watchdog(watchdog)
      return unless watchdog&.alive?

      watchdog.kill
      watchdog.join(1)
    end

    def cleanup!
      cleanup_container!
      cleanup_host_repo!
    end

    def cleanup_container!
      return unless @container

      log("containerized_runner.cleanup.start", container_id: @container.id)
      begin
        @container.stop(timeout: 5)
      rescue Docker::Error::DockerError
        # Container may already be stopped
      end
      begin
        @container.delete(force: true)
      rescue Docker::Error::DockerError
        # Container may already be removed
      end
      @container = nil
      log("containerized_runner.cleanup.success")
    end

    def cleanup_host_repo!
      return unless @host_repo_dir

      FileUtils.rm_rf(@host_repo_dir)
    ensure
      @host_repo_dir = nil
    end

    def log(message, **metadata)
      Rails.logger.info(
        message: "knowledge.#{message}",
        project_id: project.id,
        commit_sha: commit_sha,
        **metadata
      )
    end
  end
end
