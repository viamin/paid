# frozen_string_literal: true

require "base64"

module SdkBuildEnvironments
  # Collects the environment facts preflight classifies: engine identity
  # and architecture, the selected image's id/digest/platform, the actual
  # process architecture inside the image, and each toolchain binary's
  # resolved path with its ELF loader mapping. Toolchain observation runs
  # in a disposable hardened container — network-disabled, read-only root,
  # all capabilities dropped, bounded memory/CPU/PIDs — and the container
  # is always removed, success or failure. Receipts are metadata-only;
  # no credential material is read or returned.
  class MetadataProbe
    DEFAULT_COMMANDS = %w[cargo rustc rustup].freeze
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

    def container_facts
      stdout = run_disposable_probe
      parse(stdout)
    rescue Docker::Error::DockerError => e
      { process_architecture: nil, toolchains: [], probe_error: "#{e.class}: #{e.message}" }
    end

    def run_disposable_probe
      container = backend.create_container(container_config)
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
          "Resources" => {
            "Memory" => CONTAINER_MEMORY_BYTES,
            "NanoCpus" => CONTAINER_NANO_CPUS,
            "PidsLimit" => CONTAINER_PID_LIMIT
          }
        }
      }
    end

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
      SH
    end

    def parse(stdout)
      lines = Array(stdout).join.to_s.lines.map(&:strip)
      paths, headers = tool_observations(lines)
      {
        process_architecture: lines.first.presence,
        toolchains: commands.map { |command| toolchain_fact(command, paths, headers) }
      }
    end

    def tool_observations(lines)
      paths = {}
      headers = {}
      lines.each do |line|
        if (match = line.match(/\Atool\|([^|]+)\|(.*)\z/))
          paths[match[1]] = match[2].to_s
        elsif (match = line.match(/\Ahdr\|([^|]+)\|([A-Za-z0-9+\/=]+)\z/))
          headers[match[1]] = match[2]
        end
      end
      [ paths, headers ]
    end

    def toolchain_fact(command, paths, headers)
      path = paths[command].presence
      interpreter = path && headers[command] ? ElfInterpreter.for_bytes(Base64.decode64(headers[command])) : nil
      {
        command: command,
        path: path,
        interpreter_path: interpreter,
        binary_architecture: ArchitectureCompatibility.interpreter_architecture(interpreter)
      }
    end
  end
end
