# frozen_string_literal: true

require "digest"
require "socket"
require "timeout"
require "uri"

module Previews
  class TunnelManager
    DEFAULT_PORT_RANGE = "8200-8299"
    DEFAULT_SERVER_PORT = 7000
    DEFAULT_SERVER_BIND_HOST = "0.0.0.0"
    DEFAULT_LOCAL_APP_HOST = "127.0.0.1"
    DEFAULT_HEALTH_CHECK_TIMEOUT_SECONDS = 10
    HEALTH_CHECK_POLL_INTERVAL_SECONDS = 0.25

    class Error < StandardError; end
    class ConfigurationError < Error; end
    class PortExhaustedError < Error; end
    class HealthCheckError < Error; end

    TunnelDefinition = Struct.new(:session_token, :tunnel_port, :app_port, keyword_init: true) do
      def initialize(session_token:, tunnel_port:, app_port:)
        super(
          session_token: session_token.to_s,
          tunnel_port: Integer(tunnel_port),
          app_port: Integer(app_port)
        )
      end

      def service_name
        "preview-#{session_token}"
      end
    end

    ServerBinding = Struct.new(:service_name, :tunnel_port, keyword_init: true) do
      def initialize(service_name:, tunnel_port:)
        super(service_name: service_name.to_s, tunnel_port: Integer(tunnel_port))
      end
    end

    class PortPool
      def initialize(range)
        @range = range
        @mutex = Mutex.new
        @key_to_port = {}
        @port_to_key = {}
      end

      def allocate(key:)
        normalized_key = key.to_s

        @mutex.synchronize do
          return @key_to_port.fetch(normalized_key) if @key_to_port.key?(normalized_key)

          port = @range.find { |candidate| !@port_to_key.key?(candidate) }
          raise PortExhaustedError, "No preview tunnel ports available in #{@range.begin}-#{@range.end}" if port.nil?

          @key_to_port[normalized_key] = port
          @port_to_key[port] = normalized_key
          port
        end
      end

      def release(key: nil, port: nil)
        @mutex.synchronize do
          return release_key(key) if key.present?
          return release_port(port) if port.present?

          raise ArgumentError, "key or port is required"
        end
      end

      private

      def release_key(key)
        port = @key_to_port.delete(key.to_s)
        @port_to_key.delete(port) if port
        port
      end

      def release_port(port)
        normalized_port = Integer(port)
        key = @port_to_key.delete(normalized_port)
        @key_to_port.delete(key) if key
        normalized_port if key
      end
    end

    class << self
      def configure!(port_range:, server_port:, server_bind_host:, shared_token:)
        range = parse_port_range(port_range)

        Rails.application.config.x.preview_tunnel = {
          port_range: range,
          server_port: Integer(server_port),
          server_bind_host: server_bind_host.to_s,
          shared_token: shared_token.to_s
        }
        Rails.application.config.x.preview_tunnel_port_pool = PortPool.new(range)
      end

      def port_pool
        Rails.application.config.x.preview_tunnel_port_pool || default_port_pool
      end

      def allocate_port(key:)
        port_pool.allocate(key:)
      end

      def release_port(key: nil, port: nil)
        port_pool.release(key:, port:)
      end

      def server_port
        config.fetch(:server_port)
      end

      def server_bind_host
        config.fetch(:server_bind_host)
      end

      def shared_token
        config.fetch(:shared_token)
      end

      def server_config_toml(bindings: [])
        lines = [
          "[server]",
          %(bind_addr = "#{server_bind_host}:#{server_port}"),
          %(default_token = "#{toml_string(shared_token)}"),
          "",
          "[server.transport]",
          'type = "noise"'
        ]

        normalize_bindings(bindings).each do |binding|
          lines.concat([
            "",
            "[server.services.#{binding.service_name}]",
            %(bind_addr = "#{server_bind_host}:#{binding.tunnel_port}")
          ])
        end

        lines.join("\n") + "\n"
      end

      def client_config(tunnel:, backend:, restricted:)
        definition = normalize_tunnel_definition(tunnel)

        [
          "[client]",
          %(remote_addr = "#{remote_addr_for(backend:, restricted:)}"),
          %(default_token = "#{toml_string(shared_token)}"),
          "",
          "[client.transport]",
          'type = "noise"',
          "",
          "[client.services.#{definition.service_name}]",
          %(local_addr = "#{DEFAULT_LOCAL_APP_HOST}:#{definition.app_port}")
        ].join("\n") + "\n"
      end

      def wait_until_ready!(port:, host: DEFAULT_LOCAL_APP_HOST, timeout_seconds: DEFAULT_HEALTH_CHECK_TIMEOUT_SECONDS)
        Timeout.timeout(timeout_seconds, HealthCheckError, "Timed out waiting for preview tunnel #{host}:#{port}") do
          loop do
            socket = TCPSocket.new(host, port)
            socket.close
            return true
          rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, IOError, SocketError
            sleep HEALTH_CHECK_POLL_INTERVAL_SECONDS
          end
        end
      end

      def derived_shared_token
        secret = ENV["PREVIEW_TUNNEL_TOKEN"].presence || Rails.application.secret_key_base.presence
        raise ConfigurationError, "Preview tunnel shared token source is missing" if secret.blank?

        "paid-preview-#{Digest::SHA256.hexdigest("preview-tunnel:#{secret}")[0, 48]}"
      end

      def parse_port_range(value)
        match = value.to_s.match(/\A(\d+)-(\d+)\z/)
        raise ConfigurationError, "Invalid PREVIEW_PORT_RANGE: #{value.inspect}" unless match

        first = Integer(match[1])
        last = Integer(match[2])
        raise ConfigurationError, "Invalid PREVIEW_PORT_RANGE: #{value.inspect}" if first > last
        raise ConfigurationError, "Preview tunnel ports must be between 1 and 65535" unless first.between?(1, 65_535) && last.between?(1, 65_535)

        first..last
      end

      private

      def config
        Rails.application.config.x.preview_tunnel || begin
          configure!(
            port_range: ENV.fetch("PREVIEW_PORT_RANGE", DEFAULT_PORT_RANGE),
            server_port: Integer(ENV.fetch("PREVIEW_TUNNEL_SERVER_PORT", DEFAULT_SERVER_PORT)),
            server_bind_host: ENV.fetch("PREVIEW_TUNNEL_SERVER_BIND_HOST", DEFAULT_SERVER_BIND_HOST),
            shared_token: derived_shared_token
          )
          Rails.application.config.x.preview_tunnel
        end
      end

      def default_port_pool
        configure!(
          port_range: ENV.fetch("PREVIEW_PORT_RANGE", DEFAULT_PORT_RANGE),
          server_port: Integer(ENV.fetch("PREVIEW_TUNNEL_SERVER_PORT", DEFAULT_SERVER_PORT)),
          server_bind_host: ENV.fetch("PREVIEW_TUNNEL_SERVER_BIND_HOST", DEFAULT_SERVER_BIND_HOST),
          shared_token: derived_shared_token
        )
        Rails.application.config.x.preview_tunnel_port_pool
      end

      def normalize_bindings(bindings)
        Array(bindings).map do |binding|
          if binding.is_a?(ServerBinding)
            binding
          else
            ServerBinding.new(
              service_name: binding.fetch(:service_name),
              tunnel_port: binding.fetch(:tunnel_port)
            )
          end
        end
      end

      def normalize_tunnel_definition(tunnel)
        return tunnel if tunnel.is_a?(TunnelDefinition)

        TunnelDefinition.new(
          session_token: tunnel.fetch(:session_token),
          tunnel_port: tunnel.fetch(:tunnel_port),
          app_port: tunnel.fetch(:app_port)
        )
      end

      def remote_addr_for(backend:, restricted:)
        proxy_url = Containers::ProxyUrl.resolve(backend:, restricted:)
        uri = URI.parse(proxy_url)
        raise ConfigurationError, "Preview tunnel proxy URL is missing a host" if uri.host.blank?

        "#{uri.host}:#{server_port}"
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "Invalid preview tunnel proxy URL: #{e.message}"
      end

      def toml_string(value)
        value.to_s.gsub("\\", "\\\\").gsub('"', '\"')
      end
    end
  end
end
