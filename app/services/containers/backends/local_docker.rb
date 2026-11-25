# frozen_string_literal: true

require "docker-api"
require "socket"
require "timeout"

module Containers
  module Backends
    class LocalDocker < Base
      BACKING_STORE_PROBE_TIMEOUT = 2.seconds

      attr_reader :identifier

      def initialize(identifier: Containers::LOCAL_BACKEND_KEY.to_s)
        @identifier = identifier.to_s
      end

      def ping
        Docker.ping
      end

      # @spec CONTAINER-RUNTIME-049
      def system_info
        info = Docker.info
        return info unless Docker.url.to_s.start_with?("unix://")

        memory = host_memory
        return info unless memory

        total_kb = memory[/^MemTotal:\s+(\d+)\s+kB$/, 1]&.to_i
        available_kb = memory[/^MemAvailable:\s+(\d+)\s+kB$/, 1]&.to_i
        return info unless total_kb && available_kb && total_kb.positive? && total_kb * 1024 == info["MemTotal"]

        info.merge("PaidHostMemAvailable" => available_kb * 1024)
      end

      # @spec CONTAINER-RUNTIME-055
      def backing_storage_observation(now: Time.current)
        probe_path = ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"].presence
        return { reason: "backing_storage_probe_unconfigured" } unless probe_path
        return { reason: "backing_storage_probe_invalid" } unless File.directory?(probe_path)

        provenance_reason = Timeout.timeout(BACKING_STORE_PROBE_TIMEOUT) do
          backing_store_provenance_reason(probe_path)
        end
        return { reason: provenance_reason } if provenance_reason

        available_bytes = backing_store_available_bytes(probe_path)
        return { reason: "backing_storage_probe_unavailable" } unless available_bytes

        {
          scope: "verified_docker_backing_store_probe",
          available_bytes: available_bytes,
          observed_at: now
        }
      rescue SystemCallError, IOError, ArgumentError, TypeError, Timeout::Error, Docker::Error::DockerError, Excon::Error
        { reason: "backing_storage_probe_unavailable" }
      end

      def container_host_for(_container)
        identifier
      end

      def get_container(id)
        Docker::Container.get(id)
      end

      def create_container(config = nil, deadline: nil, **keyword_config)
        config ||= keyword_config
        return Docker::Container.create(config) unless deadline

        Docker::Container.create(config, connection_with_deadline(Docker.connection, deadline))
      end

      def start_container(container, deadline: nil)
        with_deadline(container, deadline) { container.start }
      end

      def stop_container(container, deadline: nil, **options)
        with_deadline(container, deadline) { container.stop(**options) }
      end

      def delete_container(container, deadline: nil, **options)
        with_deadline(container, deadline) { container.delete(**options) }
      end

      def exec_in_container(container, command, deadline: nil, **options, &block)
        with_deadline(container, deadline) { container.exec(command, **options, &block) }
      end

      def exec_in_container_with_stdin(container, command, stdin:, wait:, deadline: nil, **options, &block)
        deadline_options = deadline ? { deadline: deadline } : {}
        DockerExecWithStdin.call(container:, command:, stdin:, wait:, **deadline_options, **options, &block)
      end

      def container_stats(container, **options)
        container.stats(**options)
      end

      def container_logs(container, **options)
        container.streaming_logs(**options)
      end

      def list_containers(**options)
        Docker::Container.all(**options)
      end

      def get_network(name, deadline: nil)
        return Docker::Network.get(name) unless deadline

        Docker::Network.get(name, {}, connection_with_deadline(Docker.connection, deadline))
      end

      def create_network(name, config = nil, deadline: nil, **keyword_config)
        config ||= keyword_config
        return Docker::Network.create(name, config) unless deadline

        Docker::Network.create(name, config, connection_with_deadline(Docker.connection, deadline))
      end

      def pull_image(config)
        Docker::Image.create(config)
      end

      def get_image(name)
        Docker::Image.get(name)
      end

      def build_image(dockerfile, opts = {}, deadline: nil, &block)
        return Docker::Image.build(dockerfile, opts, &block) unless deadline

        Docker::Image.build(dockerfile, opts, connection_with_deadline(Docker.connection, deadline), &block)
      end

      def list_images(opts = {})
        Docker::Image.all(opts)
      end

      def delete_image(name, deadline: nil, **opts)
        return Docker::Image.remove(name, opts) unless deadline

        Docker::Image.remove(name, opts, connection_with_deadline(Docker.connection, deadline))
      end

      def list_volumes
        Docker::Volume.all
      end

      def create_volume(name, options = nil, host: nil, **keyword_options)
        Docker::Volume.create(name, normalize_volume_options(options, keyword_options))
      end

      def get_volume(name, host: nil)
        Docker::Volume.get(name)
      end

      def delete_volume(volume, **options)
        volume.remove(**options)
      end

      private

      def with_deadline(container, deadline)
        return yield unless deadline

        original_connection = container.connection
        container.connection = connection_with_deadline(original_connection, deadline)
        yield
      ensure
        container.connection = original_connection if original_connection
      end

      def connection_with_deadline(connection, deadline)
        return connection unless deadline

        Docker::Connection.new(connection.url, connection.options.merge(timeout: deadline, retry_limit: 0))
      end

      def host_memory
        File.read("/proc/meminfo")
      rescue SystemCallError, IOError
        nil
      end

      def backing_store_provenance_reason(probe_path)
        return "backing_storage_probe_remote_mismatch" unless Docker.url.to_s.start_with?("unix://")

        configured_root = ENV["PAID_DOCKER_BACKING_STORE_DAEMON_ROOT"].presence
        return "backing_storage_probe_unverified" unless configured_root

        actual_root = Docker.info["DockerRootDir"].presence
        return "backing_storage_probe_unverified" unless actual_root
        return "backing_storage_probe_wrong_filesystem" unless File.expand_path(configured_root) == File.expand_path(actual_root)
        "backing_storage_probe_unverified" unless probe_mounts_daemon_root?(probe_path, actual_root)
      end

      def probe_mounts_daemon_root?(probe_path, daemon_root)
        expected_root = File.join(File.expand_path(daemon_root), ".paid-capacity-probe")
        expected_target = File.expand_path(probe_path)

        mounts = backing_store_mounts.select { |_root, target, options| target == expected_target && options.include?("ro") }
        return false if mounts.empty?
        return true if mounts.any? { |root, _target, _options| root == expected_root }

        daemon_attests_probe_mount?(expected_root, expected_target)
      end

      def daemon_attests_probe_mount?(expected_root, expected_target)
        hostname = Socket.gethostname
        return false unless hostname.match?(/\A[a-f0-9]{12,64}\z/)

        info = get_container(hostname).info
        return false unless info.is_a?(Hash)
        return false unless info["Id"].to_s.start_with?(hostname) && info.dig("Config", "Hostname") == hostname

        Array(info["Mounts"]).any? do |mount|
          mount.is_a?(Hash) && mount["Type"] == "bind" && mount["RW"] == false &&
            mount["Source"] == expected_root && mount["Destination"] == expected_target
        end
      rescue Docker::Error::DockerError, Excon::Error
        false
      end

      def backing_store_mounts
        File.read("/proc/self/mountinfo").each_line.filter_map { |line| parse_mountinfo(line) }
      end

      def parse_mountinfo(line)
        fields = line.split(" - ", 2).first.to_s.split
        return unless fields.length >= 6

        [ decode_mountinfo_path(fields[3]), decode_mountinfo_path(fields[4]), fields[5].split(",") ]
      end

      def decode_mountinfo_path(path)
        path.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
      end

      def backing_store_available_bytes(probe_path)
        stdout, status = capture_backing_store_probe(probe_path)
        return unless status&.success?

        available_blocks = Integer(stdout.lines.last.to_s.split.fetch(3, nil), 10)
        return if available_blocks.negative?

        available_blocks * 1024
      rescue ArgumentError, IndexError, TypeError
        nil
      end

      def capture_backing_store_probe(probe_path)
        reader, writer = IO.pipe
        pid = Process.spawn("df", "-Pk", "--", probe_path, out: writer, err: File::NULL, pgroup: true)
        writer.close

        stdout, status = Timeout.timeout(BACKING_STORE_PROBE_TIMEOUT) do
          stdout = reader.read
          _pid, status = Process.wait2(pid)
          [ stdout, status ]
        end
        [ stdout, status ]
      rescue Timeout::Error
        [ "", nil ]
      rescue SystemCallError, IOError
        [ "", nil ]
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        terminate_backing_store_probe(pid) if pid && !status
      end

      def terminate_backing_store_probe(pid)
        signal_backing_store_probe("TERM", pid)
        signal_backing_store_probe("KILL", pid)
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end

      def signal_backing_store_probe(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end

      def normalize_volume_options(options, keyword_options)
        (options || {}).merge(keyword_options.transform_keys(&:to_s))
      end
    end
  end
end
