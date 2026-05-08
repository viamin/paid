# frozen_string_literal: true

require "docker-api"
require "open3"
require "fileutils"
require "timeout"

module Knowledge
  # Runs knowledge collectors inside an isolated Docker container.
  #
  # Uses a two-step workspace setup:
  # 1. Clones the repo on the host into a tmpdir (shallow fetch of the
  #    target commit).
  # 2. Streams the clone as a tar archive into the container via the
  #    Docker API (archive_in_stream), which works correctly in DooD
  #    environments where bind-mounting host paths would fail because
  #    the host Docker daemon cannot see devcontainer filesystem paths.
  #
  # The container uses a Docker named volume at /workspace (not a bind
  # mount), matching the pattern in Containers::Provision.
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

    # Matches the agent container memory budget (Containers::Provision
    # defaults to 4GB). The routes collector runs `bundle install` and
    # boots the target Rails app via `bin/rails routes`, which deterministically
    # exceeded the previous 512MB cap and was killed by the cgroup OOM
    # killer (exit 137). Other collectors use far less memory but share
    # this container, so we size for the heaviest workload.
    CONTAINER_DEFAULTS = {
      image: "paid-agent:latest",
      memory_bytes: 4 * 1024 * 1024 * 1024,  # 4GB
      cpu_quota: 100_000,                     # 1 CPU
      pids_limit: 200,
      timeout_seconds: 300,                   # 5 minutes
      workspace_mount: "/workspace",
      network_mode: "bridge"
    }.freeze

    COMMIT_SHA_PATTERN = /\A[0-9a-f]{40}\z/i
    PROJECT_NAME_PATTERN = %r{\A[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+\z}
    ALLOWED_NETWORK_MODES = %w[none bridge].freeze

    attr_reader :project, :commit_sha, :branch, :committed_at, :options, :host_repo_dir

    def initialize(project:, commit_sha:, branch: "main", committed_at: nil, options: {})
      @project = project
      @commit_sha = commit_sha
      @branch = branch
      @committed_at = committed_at
      @options = CONTAINER_DEFAULTS.merge(options)
      @container = nil
      @host_repo_dir = nil
      @network_connected = @options[:network_mode].to_s == "bridge"
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
      seed_workspace!
      disconnect_network! if @network_connected

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

    # Temporarily connects the container to the bridge network so it can
    # reach the internet (e.g. for `bundle install`). Must be followed by
    # disconnect_network! before executing untrusted code.
    def connect_network!
      raise ContainerError, "Container not provisioned" unless @container
      return if @network_connected
      if options[:network_mode].to_s == "none"
        raise ContainerError, "Cannot connect network for containers provisioned with network_mode=none"
      end

      log("containerized_runner.network.connect")
      bridge = Docker::Network.get("bridge")
      bridge.connect(@container.id)
      @network_connected = true
    rescue Docker::Error::DockerError => e
      return @network_connected = true if network_already_connected_error?(e)

      raise ContainerError, "Failed to connect network: #{e.message}"
    end

    # Disconnects the container from the bridge network, restoring full
    # network isolation before running untrusted code.
    def disconnect_network!
      raise ContainerError, "Container not provisioned" unless @container
      return unless @network_connected

      log("containerized_runner.network.disconnect")
      bridge = Docker::Network.get("bridge")
      bridge.disconnect(@container.id)
      @network_connected = false
    rescue Docker::Error::DockerError => e
      return @network_connected = false if network_not_connected_error?(e)

      raise ContainerError, "Failed to disconnect network: #{e.message}"
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
    def execute(command, timeout: nil, env: {})
      raise ContainerError, "Container not provisioned" unless @container

      timeout ||= options[:timeout_seconds]
      cmd_array = command.is_a?(Array) ? command : [ "sh", "-c", command ]
      exec_options = { wait: timeout }
      exec_options[:Env] = env.map { |key, value| "#{key}=#{value}" } if env.present?
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
        result = @container.exec(cmd_array, exec_options)
      rescue Docker::Error::DockerError => e
        raise TimeoutError, "Command timed out after #{timeout} seconds" if mutex.synchronize { timed_out }
        raise ContainerError, "Command execution failed: #{e.message}"
      ensure
        mutex.synchronize { exec_completed = true }
        stop_watchdog(watchdog)
      end

      raise TimeoutError, "Command timed out after #{timeout} seconds" if mutex.synchronize { timed_out }

      stdout = Array(result[0]).join
      stderr = redact_secrets(Array(result[1]).join, env)
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

      create_workspace_volume!
      @container = Docker::Container.create(container_config)
      @container.start

      log("containerized_runner.provision.success", container_id: @container.id)
    rescue Docker::Error::DockerError => e
      cleanup!
      raise ContainerError, "Failed to provision collector container: #{e.message}"
    end

    # Creates a Docker named volume for the workspace. Named volumes are
    # managed by the Docker daemon and work correctly in DooD environments
    # where bind-mounting host paths would fail.
    def create_workspace_volume!
      @workspace_volume = "paid-collector-#{project.id}-#{SecureRandom.hex(4)}"
      Docker::Volume.create(
        @workspace_volume,
        "Labels" => {
          "paid.managed" => "true",
          "paid.resource" => "collector_volume",
          "paid.project_id" => project.id.to_s
        }
      )
    end

    # Copies the host-side clone into the container via the Docker API.
    # This works in DooD because archive_in_stream sends a tar over the
    # API socket rather than relying on filesystem path visibility.
    # The tar output is streamed directly to Docker to avoid buffering
    # the entire archive in memory.
    def seed_workspace!
      stream_repo_tar_to_container!

      workspace = options[:workspace_mount]
      writable_paths = [ "#{workspace}/log", "#{workspace}/tmp" ]

      # Force root ownership so the agent user cannot restore write
      # permissions (they don't own the files). Tar preserves uid/gid
      # from the host clone, which may be a non-root user, so an
      # explicit chown is required.
      exec_setup!([ "chown", "-R", "root:root", workspace ], "set workspace ownership")

      # Pre-create Rails writable directories BEFORE locking the workspace
      # down. The routes collector boots the target Rails app via
      # `bin/rails routes`, and Rails initializes its logger by writing to
      # log/<env>.log during boot. Without writable log/, Rails aborts with
      # "Unable to access log file. Please ensure that
      # /workspace/log/development.log exists and is writable". tmp/ is
      # similarly expected by bootsnap and other boot-time writers. The
      # mkdir MUST precede the chmod below: after `chmod -R a=rX`,
      # /workspace has no write bit, and CapDrop: ALL strips
      # CAP_DAC_OVERRIDE so even root cannot create new entries there.
      exec_setup!([ "mkdir", "-p", *writable_paths ], "create Rails writable directories")

      # Set read + execute (for directories) for all users so the agent can
      # read the codebase for analysis. Collectors should write only to
      # the size-limited tmpfs locations (/tmp, /home/agent/.cache) and
      # the Rails writable dirs granted below.
      exec_setup!([ "chmod", "-R", "a=rX", workspace ], "set workspace permissions")

      # Grant the agent user ownership + write access to log/ and tmp/ only.
      # The rest of /workspace remains read-only so the agent cannot mutate
      # source code it analyzes. These two dirs are the minimal set required
      # for Rails to boot cleanly during collection; any pre-existing
      # contents (unusual for log/tmp, which are typically gitignored) are
      # also re-owned to agent so Rails can rotate/truncate them.
      exec_setup!([ "chown", "-R", "agent:agent", *writable_paths ], "set Rails writable directory ownership")
      exec_setup!([ "chmod", "-R", "u+rwX", *writable_paths ], "grant Rails writable directory permissions")
    rescue ContainerError
      raise
    rescue Docker::Error::DockerError, Errno::ENOENT => e
      raise ContainerError, "Failed to seed workspace: #{e.message}"
    end

    # Runs a workspace setup command as root and raises ContainerError on
    # non-zero exit. Centralizes the exec+check pattern so the order and
    # error shape of seed_workspace! is easy to read at a glance.
    def exec_setup!(command, failing_action)
      _stdout, _stderr, status = @container.exec(command, user: "root")
      return if status.to_i.zero?

      raise ContainerError, "Failed to #{failing_action} (exit #{status})"
    end

    def stream_repo_tar_to_container!
      Open3.popen3("tar", "-cf", "-", "-C", @host_repo_dir, ".") do |_stdin, stdout, stderr, wait_thr|
        stdout.binmode
        @container.archive_in_stream(options[:workspace_mount]) { stdout.read(8192).to_s }
        status = wait_thr.value
        unless status.success?
          error_output = stderr.read.to_s.strip
          snippet = error_output.lines.first(10).join[0, 500] unless error_output.empty?
          message = +"tar failed (exit #{status.exitstatus})"
          message << " stderr: #{snippet}" if snippet
          raise ContainerError, message
        end
      end
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
        # /tmp must be `exec` because `bundle install` builds native gem
        # extensions there. mkmf's try_link verifies the produced binary
        # with File.executable?, which returns false on a noexec mount —
        # producing a misleading "compiler failed to generate an executable
        # file" error (see e.g. bigdecimal-4.1.1 extconf.rb). Docker's
        # default tmpfs flags include noexec, so it must be overridden.
        # /home/agent/.cache needs exec because some providers (e.g. GitHub Copilot)
        # download native Node.js addons (pty.node) into ~/.cache/copilot/pkg/ at
        # runtime; dlopen() requires mmap(PROT_EXEC), which fails on a noexec mount.
        #
        # /tmp size must fit the target repo's full gem set because the
        # routes collector sets BUNDLE_PATH=/tmp/bundle and unpacks every
        # gem there. Rails 8 apps commonly ship 300–600MB of gems, so the
        # previous 256MB limit produced ENOSPC during `bundle install`.
        # 2GB gives headroom for large gem sets and transient build files;
        # tmpfs is charged against the container memory cgroup (now 4GB).
        "Tmpfs" => {
          "/tmp" => "exec,size=#{2 * 1024 * 1024 * 1024},mode=1777",
          "/home/agent/.cache" => "exec,size=#{128 * 1024 * 1024},mode=0755"
        },
        "Binds" => [
          "#{@workspace_volume}:#{options[:workspace_mount]}:rw"
        ],
        "NetworkMode" => validated_network_mode
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

    def validated_network_mode
      mode = options[:network_mode].to_s
      unless ALLOWED_NETWORK_MODES.include?(mode)
        raise ContainerError, "Invalid network_mode: #{mode.inspect}"
      end

      mode
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

    def redact_secrets(text, env)
      return text if text.blank? || env.blank?

      redacted = text.dup
      secret_values_for(env).each do |secret|
        redacted.gsub!(secret, "[REDACTED]")
      end
      redacted.gsub!(%r{x-access-token:[^@/\s]+@github\.com}, "x-access-token:[REDACTED]@github.com")
      redacted
    end

    def secret_values_for(env)
      env.each_with_object([]) do |(key, value), secrets|
        if key.match?(/TOKEN|PASSWORD|SECRET|CREDENTIAL/i)
          secrets << value
          next
        end

        secrets << Regexp.last_match(1) if value.to_s.match(%r{x-access-token:([^@/\s]+)})
      end.compact.uniq
    end

    def network_already_connected_error?(error)
      error.message.match?(/already exists in network bridge|endpoint with name .* already exists in network bridge/i)
    end

    def network_not_connected_error?(error)
      error.message.match?(/is not connected to network bridge|endpoint .* not found/i)
    end

    def cleanup!
      cleanup_container!
      cleanup_workspace_volume!
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

    def cleanup_workspace_volume!
      return unless @workspace_volume

      Docker::Volume.get(@workspace_volume).remove(force: true)
    rescue Docker::Error::NotFoundError
      # Volume already removed
    rescue Docker::Error::DockerError => e
      Rails.logger.warn(
        message: "knowledge.containerized_runner.cleanup_workspace_volume.failed",
        project_id: project.id,
        commit_sha: commit_sha,
        workspace_volume: @workspace_volume,
        error_class: e.class.name,
        error_message: e.message
      )
    ensure
      @workspace_volume = nil
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
