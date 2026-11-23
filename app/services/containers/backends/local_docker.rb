# frozen_string_literal: true

require "docker-api"

module Containers
  module Backends
    class LocalDocker < Base
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
        with_deadline(container, deadline) do
          DockerExecWithStdin.call(container:, command:, stdin:, wait:, **options, &block)
        end
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

        Docker::Connection.new(connection.url, connection.options.merge(timeout: deadline))
      end

      def host_memory
        File.read("/proc/meminfo")
      rescue SystemCallError, IOError
        nil
      end

      def normalize_volume_options(options, keyword_options)
        (options || {}).merge(keyword_options.transform_keys(&:to_s))
      end
    end
  end
end
