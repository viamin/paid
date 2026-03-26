# frozen_string_literal: true

require "docker-api"

module Knowledge
  # Runs knowledge collectors inside an isolated Docker container.
  #
  # Provisions a lightweight container (paid-agent:latest), clones the repo at
  # the target commit SHA, runs each registered collector, and extracts results.
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

    # Lightweight resource limits — collectors don't need 4GB of memory.
    CONTAINER_DEFAULTS = {
      image: "paid-agent:latest",
      memory_bytes: 512 * 1024 * 1024,  # 512MB
      cpu_quota: 100_000,                # 1 CPU
      pids_limit: 200,
      timeout_seconds: 300,              # 5 minutes
      workspace_mount: "/workspace"
    }.freeze

    attr_reader :project, :commit_sha, :branch, :committed_at, :options

    def initialize(project:, commit_sha:, branch: "main", committed_at: nil, options: {})
      @project = project
      @commit_sha = commit_sha
      @branch = branch
      @committed_at = committed_at
      @options = CONTAINER_DEFAULTS.merge(options)
      @container = nil
      @workspace_volume = nil
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
      provision_container!
      clone_repo!

      result = Knowledge::CollectorRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at,
        options: { container_runner: self }
      )

      result
    ensure
      cleanup!
    end

    # Executes a command inside the collector container and returns stdout.
    # Used by collectors via the container_runner option.
    #
    # @param command [String, Array<String>] Command to execute
    # @param timeout [Integer] Timeout in seconds
    # @return [String] stdout output
    # @raise [ContainerError] when command fails
    def execute(command, timeout: nil)
      raise ContainerError, "Container not provisioned" unless @container

      timeout ||= options[:timeout_seconds]
      cmd_array = command.is_a?(Array) ? command : [ "sh", "-c", command ]

      result = @container.exec(cmd_array, wait: timeout)

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

    def provision_container!
      log("containerized_runner.provision.start")

      create_workspace_volume!
      @container = Docker::Container.create(container_config)
      @container.start
      fix_workspace_ownership!

      log("containerized_runner.provision.success", container_id: @container.id)
    rescue Docker::Error::DockerError => e
      cleanup!
      raise ContainerError, "Failed to provision collector container: #{e.message}"
    end

    def clone_repo!
      log("containerized_runner.clone.start", commit_sha: commit_sha)

      url = "https://github.com/#{project.full_name}.git"
      mount = options[:workspace_mount]

      # Clone at the specific commit SHA using a shallow fetch.
      # First init + fetch is more reliable for specific SHAs than clone --depth=1.
      execute("git init #{mount}")
      execute("git -C #{mount} remote add origin #{url}")
      execute(
        "git -C #{mount} fetch --depth 1 origin #{commit_sha}",
        timeout: 120
      )
      execute("git -C #{mount} checkout FETCH_HEAD")

      log("containerized_runner.clone.success")
    rescue ContainerError => e
      raise CloneError, "Failed to clone repo: #{e.message}"
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
          "#{@workspace_volume}:#{options[:workspace_mount]}:rw"
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

    def create_workspace_volume!
      @workspace_volume = "paid-collector-#{project.id}-#{SecureRandom.hex(6)}"
      begin
        Docker::Volume.get(@workspace_volume)
      rescue Docker::Error::NotFoundError
        Docker::Volume.create(@workspace_volume, {
          "Labels" => {
            "paid.managed" => "true",
            "paid.resource" => "collector_workspace",
            "paid.project_id" => project.id.to_s
          }
        })
      end
    end

    def fix_workspace_ownership!
      @container.exec(
        [ "chown", "-R", "agent:agent", options[:workspace_mount] ],
        user: "root"
      )
    rescue Docker::Error::DockerError => e
      log("containerized_runner.workspace_chown_failed", error: e.message)
    end

    def cleanup!
      cleanup_container!
      cleanup_volume!
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

    def cleanup_volume!
      return unless @workspace_volume

      Docker::Volume.get(@workspace_volume).remove
    rescue Docker::Error::NotFoundError
      # Volume already removed
    rescue => e
      log("containerized_runner.volume_cleanup_failed", error: e.message)
    ensure
      @workspace_volume = nil
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
