# frozen_string_literal: true

require "docker-api"
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

      # @spec CONTAINER-RUNTIME-054
      def backing_storage_observation(now: Time.current)
        probe_path = ENV["PAID_DOCKER_BACKING_STORE_PROBE_PATH"].presence
        return { reason: "backing_storage_probe_unconfigured" } unless probe_path
        return { reason: "backing_storage_probe_invalid" } unless File.directory?(probe_path)

        provenance_reason = backing_store_provenance_reason
        return { reason: provenance_reason } if provenance_reason

        available_bytes = backing_store_available_bytes(probe_path)
        return { reason: "backing_storage_probe_unavailable" } unless available_bytes

        {
          scope: "verified_docker_backing_store_probe",
          available_bytes: available_bytes,
          observed_at: now
        }
      rescue SystemCallError, IOError, ArgumentError, TypeError, Docker::Error::DockerError, Excon::Error
        { reason: "backing_storage_probe_unavailable" }
      end

      def container_host_for(_container)
        identifier
      end

      def get_container(id)
        Docker::Container.get(id)
      end

      def create_container(config)
        Docker::Container.create(config)
      end

      def start_container(container)
        container.start
      end

      def stop_container(container, **options)
        container.stop(**options)
      end

      def delete_container(container, **options)
        container.delete(**options)
      end

      def exec_in_container(container, command, **options, &block)
        container.exec(command, **options, &block)
      end

      def exec_in_container_with_stdin(container, command, stdin:, wait:, **options, &block)
        DockerExecWithStdin.call(container:, command:, stdin:, wait:, **options, &block)
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

      def get_network(name)
        Docker::Network.get(name)
      end

      def create_network(name, config)
        Docker::Network.create(name, config)
      end

      def pull_image(config)
        Docker::Image.create(config)
      end

      def get_image(name)
        Docker::Image.get(name)
      end

      def build_image(dockerfile, opts = {}, &block)
        Docker::Image.build(dockerfile, opts, &block)
      end

      def list_images(opts = {})
        Docker::Image.all(opts)
      end

      def delete_image(name, **opts)
        Docker::Image.remove(name, opts)
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

      def host_memory
        File.read("/proc/meminfo")
      rescue SystemCallError, IOError
        nil
      end

      def backing_store_provenance_reason
        return "backing_storage_probe_remote_mismatch" unless Docker.url.to_s.start_with?("unix://")

        configured_root = ENV["PAID_DOCKER_BACKING_STORE_DAEMON_ROOT"].presence
        return "backing_storage_probe_unverified" unless configured_root

        actual_root = Docker.info["DockerRootDir"].presence
        return "backing_storage_probe_unverified" unless actual_root
        "backing_storage_probe_wrong_filesystem" unless File.expand_path(configured_root) == File.expand_path(actual_root)
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
