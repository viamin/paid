# frozen_string_literal: true

module Containers
  # Executes one application text command in a disposable container. It never
  # mounts a checkout or the Rails workspace; credentials arrive only as exec
  # environment for the selected command and disappear with the container.
  class StandaloneTextExecutor
    MAX_TIMEOUT = 120
    MAX_OUTPUT_BYTES = 2 * 1024 * 1024
    MAX_INPUT_BYTES = 1024 * 1024
    CLEANUP_MARGIN = 5
    DEFAULTS = {
      image: Containers::ImageResolver::BASE_IMAGE,
      memory_bytes: 512 * 1024 * 1024,
      cpu_quota: 100_000,
      pids_limit: 100
    }.freeze
    OUTPUT_LIMIT_EXIT_CODE = 86
    MATERIALIZE_COMMAND = <<~'PYTHON'.freeze
      import json, os, pathlib, selectors, signal, subprocess, sys, urllib.request

      def write_file(name, content, allowed_roots, mode=0o600):
          path = pathlib.Path(os.path.realpath(name))
          if not path.is_absolute() or not any(path == root or root in path.parents for root in allowed_roots):
              raise ValueError("materialized file path is outside its allowed roots")
          path.parent.mkdir(parents=True, exist_ok=True)
          path.write_text(content, encoding="utf-8")
          path.chmod(mode)

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

      preparation = json.loads(os.environ.get("PAID_TEXT_PREPARATION", "[]"))
      for write in preparation:
          mode = write["mode"] if write.get("mode") is not None else 0o600
          write_file(write["path"], write["content"], [pathlib.Path("/home/agent"), pathlib.Path("/tmp")], mode)

      command = json.loads(os.environ["PAID_TEXT_COMMAND"])
      limit = int(os.environ["PAID_MAX_OUTPUT_BYTES"])
      for name in ("PAID_CREDENTIAL_URL", "PAID_CREDENTIAL_IDENTITY", "PAID_TEXT_COMMAND", "PAID_TEXT_PREPARATION", "PAID_MAX_OUTPUT_BYTES"):
          environment.pop(name, None)
      process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
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

    def initialize(account:, runner:, timeout:)
      @account = account
      @runner = runner
      @timeout = [ timeout.to_i, MAX_TIMEOUT ].min
    end

    def execute(command, timeout: nil, env: {}, preparation: nil, **) # @spec LLM-ROUTING-003 LLM-ROUTING-005 LLM-ROUTING-006
      validate_input_size!(command, env, preparation)
      with_container do
        run(materialized_command(command), timeout: bounded_timeout(timeout),
          env: materialized_env(command, env, preparation))
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

    def validate_input_size!(command, env, preparation)
      bytes = Array(command).sum { |part| part.to_s.bytesize } +
        env.sum { |key, value| key.to_s.bytesize + value.to_s.bytesize } + preparation_json(preparation).bytesize
      return if bytes <= MAX_INPUT_BYTES

      raise AgentHarness::ConfigurationError, "Isolated text request exceeded the #{MAX_INPUT_BYTES}-byte input limit"
    end

    def materialized_command(command)
      [ "python3", "-c", MATERIALIZE_COMMAND ]
    end

    def materialized_env(command, env, preparation)
      credential_keys = credential_env_keys(env)
      wrapped = env.except(*credential_keys).compact.merge(
        "PAID_MAX_OUTPUT_BYTES" => MAX_OUTPUT_BYTES.to_s,
        "PAID_TEXT_COMMAND" => Array(command).to_json,
        "PAID_TEXT_PREPARATION" => preparation_json(preparation)
      )
      wrapped.merge(
        "PAID_CREDENTIAL_URL" => "http://paid-proxy:#{Rails.application.config.x.paid_proxy_port}/api/proxy/standalone-text-credential",
        "PAID_CREDENTIAL_IDENTITY" => StandaloneTextCredential.issue(account: account, runner: runner,
          expires_in: @timeout + CLEANUP_MARGIN, env_keys: credential_keys)
      )
    end

    def credential_env_keys(env)
      return [] unless runner.api_key?

      provider = AgentHarness.provider_class(RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym)
        .new(config: AgentHarness.build_config(RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym))
      (provider.api_key_env_var_names + env.select { |_, value| value == runner.effective_api_secret }.keys).uniq
    end

    def preparation_json(preparation)
      Array(preparation&.file_writes).map do |write|
        { path: write.path, content: write.content, mode: write.mode }
      end.to_json
    end

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
      result = Containers.backend.exec_in_container(@container, command,
        wait: timeout, Env: env.map { |key, value| "#{key}=#{value}" }) do |stream, chunk|
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
      exit_code = Array(result).last
      if output_exceeded
        raise AgentHarness::Error, "Isolated text request exceeded the #{MAX_OUTPUT_BYTES}-byte output limit"
      end
      if exit_code.to_i == OUTPUT_LIMIT_EXIT_CODE
        raise AgentHarness::Error, "Isolated text request exceeded the #{MAX_OUTPUT_BYTES}-byte output limit"
      end
      raise AgentHarness::TimeoutError, "Isolated text request timed out" if timed_out || exit_code.to_i == 124

      AgentHarness::CommandExecutor::Result.new(stdout: stdout, stderr: stderr,
        exit_code: exit_code.to_i, duration: nil)
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
          "Tmpfs" => { "/tmp" => "exec,size=#{64 * 1024 * 1024},mode=1777", "/home/agent" => "size=#{64 * 1024 * 1024},mode=0700,uid=1000,gid=1000" },
          "NetworkMode" => NetworkPolicy::NETWORK_NAME
        },
        "Env" => [ "HOME=/home/agent" ],
        "Labels" => { "paid.managed" => "true", "paid.resource" => "standalone_text_container", "paid.account_id" => account.id.to_s, "paid.runner_id" => runner.id.to_s },
        "Tty" => false, "OpenStdin" => false, "Cmd" => [ "tail", "-f", "/dev/null" ]
      }
    end
  end
end
