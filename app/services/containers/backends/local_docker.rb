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

      def system_info
        Docker.info
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

      def normalize_volume_options(options, keyword_options)
        (options || {}).merge(keyword_options.transform_keys(&:to_s))
      end
    end
  end
end
