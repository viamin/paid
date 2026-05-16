# frozen_string_literal: true

require "docker-api"
require "uri"

module Containers
  module Backends
    class RemoteDocker < Base
      DEFAULT_PORT = 2376
      REQUIRED_TLS_OPTIONS = {
        client_cert: "REMOTE_DOCKER_CERT",
        client_key: "REMOTE_DOCKER_KEY",
        ssl_ca_file: "REMOTE_DOCKER_CA"
      }.freeze

      attr_reader :connection, :docker_url, :identifier

      def self.from_env(env = ENV)
        host = env["REMOTE_DOCKER_HOST"].presence
        return unless host

        new(
          host: host,
          identifier: env["REMOTE_DOCKER_IDENTIFIER"].presence,
          tls_config: REQUIRED_TLS_OPTIONS.to_h { |key, env_key| [ key, env[env_key].presence ] }
        )
      end

      def initialize(host:, identifier: nil, tls_config:)
        @docker_url = normalize_url(host)
        @identifier = identifier.presence || derive_identifier(@docker_url)
        @tls_config = build_tls_config(tls_config)
        validate_tls_config!
        @connection = Docker::Connection.new(@docker_url, @tls_config)
      end

      def remote?
        true
      end

      def supports_host_paths?
        false
      end

      def owns_host?(host)
        host.present? && host.to_s == remote_host
      end

      def ping
        Docker.ping(connection)
      end

      def get_container(id)
        Docker::Container.get(id, {}, connection)
      end

      def create_container(config)
        Docker::Container.create(config, connection)
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
        Docker::Container.all(options, connection)
      end

      def get_network(name)
        Docker::Network.get(name, {}, connection)
      end

      def create_network(name, config)
        Docker::Network.create(name, config, connection)
      end

      def pull_image(config)
        Docker::Image.create(config, nil, connection)
      end

      def list_volumes
        Docker::Volume.all({}, connection)
      end

      def create_volume(name, options = nil, host: nil, **keyword_options)
        Docker::Volume.create(name, normalize_volume_options(options, keyword_options), connection)
      end

      def get_volume(name, host: nil)
        Docker::Volume.get(name, connection)
      end

      def delete_volume(volume, **options)
        volume.remove(**options)
      end

      private

      def build_tls_config(tls_config)
        tls_config.to_h.compact.merge(scheme: "https")
      end

      def normalize_volume_options(options, keyword_options)
        (options || {}).merge(keyword_options.transform_keys(&:to_s))
      end

      def validate_tls_config!
        missing = REQUIRED_TLS_OPTIONS.keys.reject { |key| @tls_config[key].present? }
        return if missing.empty?

        missing_env_keys = missing.map { |key| REQUIRED_TLS_OPTIONS.fetch(key) }
        raise ArgumentError, "Remote Docker TLS config requires #{missing_env_keys.join(', ')}"
      end

      def normalize_url(host)
        url = host.to_s
        url = "tcp://#{url}" unless url.include?("://")

        uri = URI.parse(url)
        return url if uri.port

        "#{url}:#{DEFAULT_PORT}"
      rescue URI::InvalidURIError => e
        raise ArgumentError, "Invalid remote Docker host #{host.inspect}: #{e.message}"
      end

      def derive_identifier(url)
        URI.parse(url).host
      rescue URI::InvalidURIError
        nil
      end

      def remote_host
        @remote_host ||= URI.parse(@docker_url).host
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
