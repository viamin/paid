# frozen_string_literal: true

require "base64"

module SdkBuildEnvironments
  # Collects the environment facts preflight classifies: engine identity
  # and architecture, the selected image's id/digest/platform, the actual
  # process architecture inside the image, and each toolchain binary's
  # resolved path, ELF loader mapping, and required-command execution status.
  # Toolchain observation runs
  # in a disposable hardened container — network-disabled, read-only root,
  # all capabilities dropped, bounded memory/CPU/PIDs — and the container
  # is always removed, success or failure. Backends that cannot enforce
  # that isolation are rejected before any container starts. Receipts are
  # metadata-only; no credential material is read or returned.
  class MetadataProbe
    # @spec RUST-SDK-BUILD-010
    DEFAULT_COMMANDS = %w[cargo rustc rustup].freeze
    REQUIRED_EXECUTION_COMMANDS = %w[cargo rustc].freeze
    COMMAND_FORMAT = /\A[a-z_][a-z0-9_-]*\z/.freeze
    HEADER_BYTES = 4096
    CONTAINER_MEMORY_BYTES = 128 * 1024 * 1024
    CONTAINER_NANO_CPUS = 500_000_000
    CONTAINER_PID_LIMIT = 32
    PROBE_DEADLINE_SECONDS = 30

    class << self
      def call(backend:, image:, commands: DEFAULT_COMMANDS)
        new(backend:, image:, commands:).call
      end
    end

    attr_reader :backend, :image, :commands

    def initialize(backend:, image:, commands: DEFAULT_COMMANDS)
      unless commands.all? { |command| command.match?(COMMAND_FORMAT) }
        raise ArgumentError, "probe commands must be plain command names: #{commands.inspect}"
      end

      @backend = backend
      @image = image
      @commands = commands.freeze
    end

    def call
      static_facts.merge(container_facts)
    rescue Docker::Error::DockerError => e
      metadata_error_facts(e)
    end

    private

    def static_facts
      info = backend.system_info
      image_info = backend.get_image(image).info
      {
        backend_identifier: backend.identifier,
        engine_architecture: info["Architecture"],
        image: {
          reference: image,
          id: image_info["Id"],
          digest: repo_digest(image_info),
          platform: image_info["Architecture"]
        }
      }
    end

    def repo_digest(image_info)
      Array(image_info["RepoDigests"]).first.to_s.split("@", 2).last.presence
    end

    # Image and engine inspection are external Docker operations too. Preserve
    # the receipt contract when either is unavailable so the rake boundary can
    # report an actionable unverifiable verdict instead of leaking an exception.
    def metadata_error_facts(error)
      {
        backend_identifier: backend.identifier,
        engine_architecture: nil,
        image: { reference: image, id: nil, digest: nil, platform: nil },
        process_architecture: nil,
        toolchains: [],
        probe_error: "#{error.class}: #{error.message}"
      }
    end

    def container_facts
      return unsupported_isolation_facts unless backend.supports_network_disabled_containers?

      stdout = run_disposable_probe
      parse(stdout)
    rescue Docker::Error::DockerError => e
      { process_architecture: nil, toolchains: [], probe_error: "#{e.class}: #{e.message}" }
    end

    # @spec RUST-SDK-BUILD-012
    # The probe executes toolchain binaries from an operator-selected
    # image, so a network-disabled container is part of its contract, not
    # decoration. Backends that cannot enforce it (the Swarm service API
    # has no NetworkDisabled equivalent) are rejected before any container
    # is created: the receipt records the refusal as a probe failure
    # instead of silently probing on the backend's default network.
    def unsupported_isolation_facts
      {
        process_architecture: nil,
        toolchains: [],
        probe_error: "backend #{backend.identifier.inspect} cannot enforce a network-disabled probe container; " \
                     "run preflight on a Docker Engine backend (local or remote)"
      }
    end

    def run_disposable_probe
      container = backend.create_container(container_config, deadline: PROBE_DEADLINE_SECONDS)
      backend.start_container(container, deadline: PROBE_DEADLINE_SECONDS)
      stdout, _stderr, _exit_code = backend.exec_in_container(container, [ "sh", "-c", probe_script ],
        deadline: PROBE_DEADLINE_SECONDS)
      Array(stdout).join
    ensure
      backend.delete_container(container, deadline: PROBE_DEADLINE_SECONDS, force: true) if container
    end

    def container_config
      {
        "Image" => image,
        # Keeps the container alive for the exec probe only.
        "Cmd" => [ "sh", "-c", "sleep #{PROBE_DEADLINE_SECONDS}" ],
        "User" => "nobody",
        "NetworkDisabled" => true,
        "Labels" => { "dev.paid.sdk-build-preflight" => "true" },
        "HostConfig" => {
          "ReadonlyRootfs" => true,
          "CapDrop" => [ "ALL" ],
          "Memory" => CONTAINER_MEMORY_BYTES,
          "NanoCpus" => CONTAINER_NANO_CPUS,
          "PidsLimit" => CONTAINER_PID_LIMIT
        }
      }
    end

    # Runs only version commands, suppressing their output, so the receipt
    # establishes executability without capturing potentially noisy tool output.
    def probe_script
      <<~SH
        uname -m
        for t in #{commands.join(' ')}; do
          p=$(command -v "$t" 2>/dev/null) || p=
          printf 'tool|%s|%s\\n' "$t" "$p"
          if [ -n "$p" ]; then
            printf 'hdr|%s|' "$t"
            head -c #{HEADER_BYTES} "$p" | base64 | tr -d '\\n'
            printf '\\n'
          fi
        done
        for t in #{REQUIRED_EXECUTION_COMMANDS.join(' ')}; do
          if command -v "$t" >/dev/null 2>&1; then
            "$t" --version >/dev/null 2>&1
            status=$?
          else
            status=127
          fi
          printf 'exec|%s|%s\\n' "$t" "$status"
        done
      SH
    end

    def parse(stdout)
      lines = Array(stdout).join.to_s.lines.map(&:strip)
      paths, headers, execution_statuses = tool_observations(lines)
      {
        process_architecture: lines.first.presence,
        toolchains: commands.map { |command| toolchain_fact(command, paths, headers, execution_statuses) }
      }
    end

    def tool_observations(lines)
      paths = {}
      headers = {}
      execution_statuses = {}
      lines.each do |line|
        if (match = line.match(/\Atool\|([^|]+)\|(.*)\z/))
          paths[match[1]] = match[2].to_s
        elsif (match = line.match(/\Ahdr\|([^|]+)\|([A-Za-z0-9+\/=]+)\z/))
          headers[match[1]] = match[2]
        elsif (match = line.match(/\Aexec\|([^|]+)\|(\d+)\z/))
          execution_statuses[match[1]] = match[2].to_i
        end
      end
      [ paths, headers, execution_statuses ]
    end

    def toolchain_fact(command, paths, headers, execution_statuses)
      path = paths[command].presence
      interpreter = path && headers[command] ? ElfInterpreter.for_bytes(Base64.decode64(headers[command])) : nil
      {
        command: command,
        path: path,
        interpreter_path: interpreter,
        binary_architecture: ArchitectureCompatibility.interpreter_architecture(interpreter),
        execution_status: execution_statuses[command]
      }
    end
  end
end
