# frozen_string_literal: true

module Containers
  # Executes one application text command in a disposable container. It never
  # mounts a checkout or the Rails workspace; credentials arrive only as exec
  # environment for the selected command and disappear with the container.
  class StandaloneTextExecutor
    MAX_TIMEOUT = 120
    CLEANUP_MARGIN = 5
    DEFAULTS = {
      image: Containers::ImageResolver::BASE_IMAGE,
      memory_bytes: 512 * 1024 * 1024,
      cpu_quota: 100_000,
      pids_limit: 100
    }.freeze

    def initialize(account:, runner:, timeout:)
      @account = account
      @runner = runner
      @timeout = [ timeout.to_i, MAX_TIMEOUT ].min
    end

    def execute(command, timeout: nil, env: {}, **)
      with_container do
        run(command, timeout: bounded_timeout(timeout), env: env)
      end
    end

    def which(binary)
      result = execute([ "sh", "-c", "command -v -- #{Shellwords.escape(binary.to_s)}" ])
      result.stdout.strip.presence if result.exit_code.zero?
    end

    def available?(binary)
      which(binary).present?
    end

    private

    attr_reader :account, :runner

    def with_container
      provision!
      yield
    ensure
      cleanup!
    end

    def provision!
      ExecutionRunners::LocalDockerRunner.ensure_agent_network!(backend: Containers.backend)
      @container = Containers.backend.create_container(container_config)
      Containers.backend.start_container(@container)
    rescue Docker::Error::DockerError, NetworkPolicy::Error => e
      raise AgentHarness::ConfigurationError, "Unable to provision isolated text execution: #{e.message}"
    end

    def run(command, timeout:, env:)
      timed_out = false
      finished = false
      mutex = Mutex.new
      watchdog = Thread.new do
        sleep(timeout + CLEANUP_MARGIN)
        mutex.synchronize { timed_out = !finished }
        Containers.backend.stop_container(@container, timeout: 0) if timed_out
      rescue Docker::Error::DockerError
        nil
      end
      result = Containers.backend.exec_in_container(@container, command,
        wait: timeout, Env: env.map { |key, value| "#{key}=#{value}" })
      stdout, stderr, exit_code = result
      raise AgentHarness::TimeoutError, "Isolated text request timed out" if timed_out || exit_code.to_i == 124

      AgentHarness::CommandExecutor::Result.new(stdout: Array(stdout).join, stderr: Array(stderr).join,
        exit_code: exit_code.to_i, duration: nil)
    rescue Docker::Error::DockerError => e
      raise AgentHarness::TimeoutError, "Isolated text request timed out" if timed_out

      raise AgentHarness::Error, "Isolated text execution failed: #{e.message}"
    ensure
      mutex&.synchronize { finished = true }
      watchdog&.kill
      watchdog&.join(1)
    end

    def cleanup!
      return unless @container

      Containers.backend.stop_container(@container, timeout: 0)
    rescue Docker::Error::DockerError
      nil
    ensure
      begin
        Containers.backend.delete_container(@container, force: true) if @container
      rescue Docker::Error::DockerError
        nil
      end
      @container = nil
    end

    def bounded_timeout(value)
      [ (value || @timeout).to_i, @timeout, MAX_TIMEOUT ].min
    end

    def container_config
      {
        "Image" => DEFAULTS[:image], "name" => "paid-text-#{account.id}-#{SecureRandom.hex(4)}",
        "User" => "agent", "ReadonlyRootfs" => true, "CapDrop" => [ "ALL" ],
        "SecurityOpt" => [ "no-new-privileges:true" ], "WorkingDir" => "/home/agent",
        "HostConfig" => {
          "Memory" => DEFAULTS[:memory_bytes], "MemorySwap" => DEFAULTS[:memory_bytes],
          "CpuPeriod" => 100_000, "CpuQuota" => DEFAULTS[:cpu_quota], "PidsLimit" => DEFAULTS[:pids_limit],
          "Tmpfs" => { "/tmp" => "exec,size=#{64 * 1024 * 1024},mode=1777", "/home/agent/.cache" => "size=#{64 * 1024 * 1024},mode=0700" },
          "NetworkMode" => NetworkPolicy::NETWORK_NAME
        },
        "Env" => [ "HOME=/home/agent" ],
        "Labels" => { "paid.managed" => "true", "paid.resource" => "standalone_text_container", "paid.account_id" => account.id.to_s, "paid.runner_id" => runner.id.to_s },
        "Tty" => false, "OpenStdin" => false, "Cmd" => [ "tail", "-f", "/dev/null" ]
      }
    end
  end
end
