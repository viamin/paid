# frozen_string_literal: true

require "timeout"

require "stringio"

module Containers
  # Executes one application text command in a disposable container. It never
  # mounts a checkout or the Rails workspace; credentials arrive only as exec
  # environment for the selected command and disappear with the container.
  class StandaloneTextExecutor
    class DeadlineExceeded < StandardError; end

    MAX_OUTPUT_BYTES = 2 * 1024 * 1024
    MAX_INPUT_BYTES = 1024 * 1024
    # Linux caps a single execve argument or environment string at MAX_ARG_STRLEN
    # (128 KiB), so any env entry larger than this fails inside Docker exec even
    # when the aggregate input stays within MAX_INPUT_BYTES. Values that must
    # reach the command travel on the upgraded exec stdin stream instead (see
    # #input_payload); caller env entries stay in exec env and are rejected
    # above this conservative per-entry bound, leaving headroom for the
    # "NAME=" prefix and NUL terminator.
    MAX_ENV_ENTRY_BYTES = 64 * 1024
    CLEANUP_MARGIN = 5
    STANDALONE_TEXT_MAX_LIFETIME = 10.minutes
    DEFAULTS = {
      image: Containers::ImageResolver::BASE_IMAGE,
      memory_bytes: 1024 * 1024 * 1024,
      cpu_quota: 100_000,
      pids_limit: 100
    }.freeze
    OUTPUT_LIMIT_EXIT_CODE = 86
    MATERIALIZE_COMMAND = <<~'PYTHON'.freeze
      import json, os, pathlib, selectors, signal, subprocess, sys, threading, urllib.request

      def write_file(name, content, allowed_roots, mode=0o600):
          path = pathlib.Path(os.path.realpath(os.path.expanduser(name)))
          if not path.is_absolute() or not any(path == root or root in path.parents for root in allowed_roots):
              raise ValueError("materialized file path is outside its allowed roots")
          path.parent.mkdir(parents=True, exist_ok=True)
          path.write_text(content, encoding="utf-8")
          path.chmod(mode)

      header = json.loads(sys.stdin.buffer.readline())
      expected_bytes = int(header.get("stdin_bytes", 0))
      stdin_data = sys.stdin.buffer.read(expected_bytes)
      if len(stdin_data) != expected_bytes:
          raise EOFError("isolated text input ended before the declared length")

      environment = os.environ.copy()
      if "PAID_CREDENTIAL_IDENTITY" in os.environ:
          request = urllib.request.Request(
              os.environ["PAID_CREDENTIAL_URL"],
              data=b"",
              headers={"Authorization": "Bearer " + os.environ["PAID_CREDENTIAL_IDENTITY"]},
          )
          with urllib.request.urlopen(request, timeout=10) as response:
              material = json.load(response)
          for name, content in material.get("files", {}).items():
              write_file(name, content, [pathlib.Path("/home/agent")])
          environment.update({str(key): str(value) for key, value in material.get("env", {}).items()})
      for write in header.get("preparation", []):
          mode = write["mode"] if write.get("mode") is not None else 0o600
          write_file(write["path"], write["content"], [pathlib.Path("/home/agent"), pathlib.Path("/tmp")], mode)

      command = header["command"]
      limit = int(os.environ["PAID_MAX_OUTPUT_BYTES"])
      for name in ("PAID_CREDENTIAL_URL", "PAID_CREDENTIAL_IDENTITY", "PAID_MAX_OUTPUT_BYTES"):
          environment.pop(name, None)
      process = subprocess.Popen(command, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
      def feed_stdin():
          try:
              process.stdin.write(stdin_data)
              process.stdin.close()
          except BrokenPipeError:
              pass
      threading.Thread(target=feed_stdin, daemon=True).start()
      selector = selectors.DefaultSelector()
      selector.register(process.stdout, selectors.EVENT_READ, sys.stdout.buffer)
      selector.register(process.stderr, selectors.EVENT_READ, sys.stderr.buffer)
      written = 0
      exceeded = False
      while selector.get_map():
          for key, _ in selector.select():
              chunk = key.fileobj.read1(65536)
              if not chunk:
                  selector.unregister(key.fileobj)
                  continue
              remaining = limit - written
              if remaining > 0:
                  key.data.write(chunk[:remaining])
                  key.data.flush()
                  written += min(len(chunk), remaining)
              if len(chunk) > remaining:
                  exceeded = True
                  os.killpg(process.pid, signal.SIGKILL)
                  selector.close()
                  break
          if exceeded:
              break
      process.wait()
      sys.exit(86 if exceeded else process.returncode)
    PYTHON

    def initialize(account:, runner:, timeout:, deadline: nil, clock: Process.method(:clock_gettime))
      @account = account
      @runner = runner
      @timeout = timeout.to_i
      @deadline = deadline
      @clock = clock
    end

    def execute(command, timeout: nil, env: {}, preparation: nil, stdin_data: nil, output_observer: nil, **) # @spec LLM-ROUTING-003 LLM-ROUTING-005 LLM-ROUTING-006 LLM-ROUTING-013
      validate_input_size!(command, env, preparation, stdin_data)
      raise AgentHarness::TimeoutError, "Isolated text request timed out" if deadline_expired?

      provision! unless @container
      timeout = bounded_timeout(timeout)
      raise AgentHarness::TimeoutError, "Isolated text request timed out" unless timeout.positive?

      with_managed_credential_lease(timeout: execution_credential_lease_timeout(timeout)) do
        execution_env = materialized_env(env)
        timeout = bounded_timeout(timeout)
        raise AgentHarness::TimeoutError, "Isolated text request timed out" unless timeout.positive?

        run(materialized_command, timeout: timeout, env: execution_env,
          input: input_payload(command, preparation, stdin_data), output_observer: output_observer)
      end
    rescue DeadlineExceeded
      close
      raise AgentHarness::TimeoutError, "Isolated text request timed out"
    rescue StandardError
      close
      raise
    end

    def close
      harvest_managed_credential if @container
    ensure
      cleanup!
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

    def validate_input_size!(command, env, preparation, stdin_data)
      validate_env_entry_sizes!(env)
      bytes = Array(command).sum { |part| part.to_s.bytesize } +
        env.sum { |key, value| key.to_s.bytesize + value.to_s.bytesize } + preparation_file_writes(preparation).to_json.bytesize +
        stdin_data.to_s.bytesize
      return if bytes <= MAX_INPUT_BYTES

      raise AgentHarness::ConfigurationError, "Isolated text request exceeded the #{MAX_INPUT_BYTES}-byte input limit"
    end

    def validate_env_entry_sizes!(env)
      oversized = env.find { |key, value| key.to_s.bytesize + value.to_s.bytesize > MAX_ENV_ENTRY_BYTES }
      return unless oversized

      raise AgentHarness::ConfigurationError,
        "Isolated text request env entry #{oversized.first} exceeded the #{MAX_ENV_ENTRY_BYTES}-byte per-entry exec limit"
    end

    def materialized_command
      [ "python3", "-c", MATERIALIZE_COMMAND ]
    end

    # Command, preparation, and stdin travel as one bounded stream.
    # Docker exec requires an upgraded connection to attach stdin reliably.
    def input_payload(command, preparation, stdin_data)
      input = stdin_data.to_s
      header = { "command" => Array(command).map(&:to_s),
                 "preparation" => preparation_file_writes(preparation),
                 "stdin_bytes" => input.bytesize }.to_json
      payload = header.dup.force_encoding(Encoding::BINARY)
      payload << "\n" << input.b
      StringIO.new(payload)
    end

    def preparation_file_writes(preparation)
      Array(preparation&.file_writes).map do |write|
        { "path" => write.path, "content" => write.content, "mode" => write.mode }
      end
    end

    def materialized_env(env)
      credential_keys = credential_env_keys(env)
      wrapped = env.except(*credential_keys).compact.merge(
        "PAID_MAX_OUTPUT_BYTES" => MAX_OUTPUT_BYTES.to_s
      )
      wrapped.merge(
        "PAID_CREDENTIAL_URL" => "#{Containers::ProxyUrl.resolve(backend: Containers.backend, restricted: false)}/api/proxy/standalone-text-credential",
        "PAID_CREDENTIAL_IDENTITY" => StandaloneTextCredential.issue(account: account, runner: runner,
          expires_in: credential_expires_in, env_keys: credential_keys)
      )
    end

    def credential_env_keys(env)
      return [] unless runner.api_key?

      provider = AgentHarness.provider_class(RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym)
        .new(config: AgentHarness.build_config(RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym))
      (provider.api_key_env_var_names + env.select { |_, value| value == runner.effective_api_secret }.keys).uniq
    end

    def with_managed_credential_lease(timeout: nil)
      credential = rotating_subscription_credential
      return yield unless credential

      Runners::ManagedCredentialLifecycle.with_managed_auth_lease(runner_key: runner.runner_key,
        credential: credential, timeout: timeout || managed_credential_lease_timeout) { yield }
    end

    def managed_credential_lease_timeout
      return Runners::ManagedCredentialLifecycle::DEFAULT_LOCK_TIMEOUT_SECONDS unless @deadline

      [ @deadline - monotonic_now, 0 ].max
    end

    def execution_credential_lease_timeout(timeout)
      bounded_timeout(timeout) if @deadline
    end

    def harvest_managed_credential # @spec LLM-ROUTING-005 SUBSCRIPTION-RUNNER-AUTH-005
      credential = rotating_subscription_credential
      return unless credential

      with_managed_credential_lease do
        result = Runners::ManagedCredentialLifecycle.harvest(credential: credential,
          runner_key: runner.runner_key, backend: Containers.backend, container: @container)
        log_harvest(result, credential)
      end
    end

    def rotating_subscription_credential
      return nil if runner.api_key?
      return nil unless Runners::ManagedCredentialLifecycle.rotating?(runner.runner_key)

      Runners::ManagedCredentialLifecycle.credential_for(account:, runner_key: runner.runner_key)
    end

    def log_harvest(result, credential)
      degraded = !result.performed? && result.reason != "no_rotated_credential"
      Rails.logger.public_send(degraded ? :warn : :info,
        message: "containers.standalone_text_executor.credential_harvest",
        runner_key: runner.runner_key, credential_id: credential.id, account_id: account.id,
        outcome: result.reason)
    end

    def provision!
      within_deadline { NetworkPolicy.ensure_network!(network: NetworkPolicy::INFRA_NETWORK_NAME, backend: Containers.backend) }
      @container = within_deadline { Containers.backend.create_container(container_config) }
      within_deadline { Containers.backend.start_container(@container) }
      result = within_deadline do
        Containers.backend.exec_in_container(@container,
          [ "sh", "-c", "chown agent:agent /home/agent && stat -c '%u:%g' /home/agent" ], user: "root")
      end
      status = Array(result).last
      raise AgentHarness::Error, "Isolated text home preparation exit status unavailable" if status.nil?
      raise AgentHarness::ConfigurationError, "Unable to prepare isolated text home" unless status == 0

      owner = Array(Array(result).first).join.match(/\A(\d+):(\d+)\s*\z/)
      raise AgentHarness::Error, "Isolated text home ownership unavailable" unless owner

      @agent_uid, @agent_gid = owner.captures.map(&:to_i)
    rescue Docker::Error::TimeoutError
      raise AgentHarness::TimeoutError, "Isolated text request timed out during provisioning"
    rescue Docker::Error::DockerError, NetworkPolicy::Error => e
      raise AgentHarness::ConfigurationError, "Unable to provision isolated text execution: #{e.message}"
    end

    def run(command, timeout:, env:, input:, output_observer:)
      timed_out = false
      finished = false
      mutex = Mutex.new
      completion = ConditionVariable.new
      watchdog = Thread.new do
        mutex.synchronize do
          completion.wait(mutex, timeout + CLEANUP_MARGIN) unless finished
          timed_out = !finished
        end
        Containers.backend.stop_container(@container, timeout: 0) if timed_out
      rescue Docker::Error::DockerError
        nil
      end
      stdout = +""
      stderr = +""
      output_exceeded = false
      result = within_command_timeout(timeout) do
        Containers.backend.exec_in_container_with_stdin(@container, command,
          wait: timeout, stdin: input, Env: env.map { |key, value| "#{key}=#{value}" }) do |stream, chunk|
          output_observer&.call(stream, chunk)
          next if output_exceeded

          target = stream == :stderr ? stderr : stdout
          remaining = MAX_OUTPUT_BYTES - stdout.bytesize - stderr.bytesize
          target << chunk.to_s.byteslice(0, [ remaining, 0 ].max) if remaining.positive?
          next unless chunk.to_s.bytesize > remaining

          output_exceeded = true
          begin
            Containers.backend.stop_container(@container, timeout: 0)
          rescue Docker::Error::DockerError
            nil
          end
        end
      end
      exit_code = Array(result).last
      if output_exceeded
        raise AgentHarness::Error, "Isolated text request exceeded the #{MAX_OUTPUT_BYTES}-byte output limit"
      end
      if exit_code.to_i == OUTPUT_LIMIT_EXIT_CODE
        raise AgentHarness::Error, "Isolated text request exceeded the #{MAX_OUTPUT_BYTES}-byte output limit"
      end
      raise AgentHarness::TimeoutError, "Isolated text request timed out" if timed_out || exit_code.to_i == 124
      raise AgentHarness::Error, "Isolated text execution failed: exit status unavailable" if exit_code.nil?

      AgentHarness::CommandExecutor::Result.new(stdout: stdout, stderr: stderr,
        exit_code: exit_code.to_i, duration: nil)
    rescue Docker::Error::TimeoutError
      raise AgentHarness::TimeoutError, "Isolated text request timed out"
    rescue Docker::Error::DockerError => e
      raise AgentHarness::TimeoutError, "Isolated text request timed out" if timed_out

      raise AgentHarness::Error, "Isolated text execution failed: #{e.message}"
    ensure
      mutex&.synchronize do
        finished = true
        completion&.broadcast
      end
      watchdog&.join(1)
    end

    def cleanup!
      return unless @container

      within_deadline { Containers.backend.stop_container(@container, timeout: 0) }
    rescue Docker::Error::DockerError
      nil
    rescue DeadlineExceeded
      defer_cleanup!
    ensure
      begin
        within_deadline { Containers.backend.delete_container(@container, force: true) } if @container
      rescue Docker::Error::DockerError
        nil
      rescue DeadlineExceeded
        defer_cleanup!
      else
        @container = nil
      end
    end

    def bounded_timeout(value)
      timeout = [ (value || @timeout).to_f, @timeout ].min
      @deadline ? [ timeout, @deadline - monotonic_now - CLEANUP_MARGIN ].min : timeout
    end

    def credential_expires_in
      return @timeout + CLEANUP_MARGIN unless @deadline

      [ @deadline - monotonic_now, 0 ].max
    end

    def deadline_expired?
      @deadline && @deadline <= monotonic_now
    end

    def within_deadline
      return yield unless @deadline

      Timeout.timeout(remaining_deadline, DeadlineExceeded) { yield }
    end

    def within_command_timeout(timeout)
      return yield unless @deadline

      Timeout.timeout(timeout, DeadlineExceeded) { yield }
    end

    def remaining_deadline
      remaining = @deadline - monotonic_now
      raise DeadlineExceeded unless remaining.positive?

      remaining
    end

    def defer_cleanup!
      Rails.logger.warn(
        message: "containers.standalone_text_executor.cleanup_deferred",
        container_id: @container.id,
        account_id: account.id,
        runner_id: runner.id
      )
    end

    def monotonic_now
      @clock.call(Process::CLOCK_MONOTONIC)
    end

    def container_config
      {
        "Image" => DEFAULTS[:image], "name" => "paid-text-#{account.id}-#{SecureRandom.hex(4)}",
        "User" => "agent", "ReadonlyRootfs" => true, "CapDrop" => [ "ALL" ],
        "SecurityOpt" => [ "no-new-privileges:true" ], "WorkingDir" => "/home/agent",
        "HostConfig" => {
          "Memory" => DEFAULTS[:memory_bytes], "MemorySwap" => DEFAULTS[:memory_bytes],
          "CpuPeriod" => 100_000, "CpuQuota" => DEFAULTS[:cpu_quota], "PidsLimit" => DEFAULTS[:pids_limit],
          "Tmpfs" => { "/tmp" => "exec,size=#{64 * 1024 * 1024},mode=1777", "/home/agent" => "size=#{256 * 1024 * 1024},mode=0700,uid=1000,gid=1000" },
          "NetworkMode" => NetworkPolicy::INFRA_NETWORK_NAME
        },
        "Env" => [ "HOME=/home/agent" ],
        "Labels" => {
          "paid.managed" => "true", "paid.resource" => "standalone_text_container",
          "paid.account_id" => account.id.to_s, "paid.runner_id" => runner.id.to_s,
          "paid.expires_at" => STANDALONE_TEXT_MAX_LIFETIME.from_now.iso8601
        },
        "Tty" => false, "OpenStdin" => false, "Cmd" => [ "tail", "-f", "/dev/null" ]
      }
    end
  end
end
