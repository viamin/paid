# frozen_string_literal: true

require "digest"
require "net/http"
require "securerandom"
require "set"
require "shellwords"
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
    DEFAULT_SERVER_CONFIG_POLL_INTERVAL_SECONDS = 2
    DEFAULT_STALE_RESERVATION_GRACE_PERIOD = 15.minutes
    HEALTH_CHECK_POLL_INTERVAL_SECONDS = 0.25
    RESERVATION_LOCK_KEY = Digest::SHA256.hexdigest(name).to_i(16) % (2**31 - 1)
    PREVIEW_TUNNEL_LABEL = "paid.preview_tunnel"
    PREVIEW_SESSION_TOKEN_LABEL = "paid.preview_session_token"
    PREVIEW_SERVICE_NAME_LABEL = "paid.preview_service_name"
    PREVIEW_TUNNEL_PORT_LABEL = "paid.preview_tunnel_port"
    CLIENT_CONFIG_PATH = "tmp/paid-preview-rathole.toml"
    CLIENT_LOG_PATH = "tmp/paid-preview-rathole.log"
    CLIENT_PID_PATH = "tmp/paid-preview-rathole.pid"

    class Error < StandardError; end
    class ConfigurationError < Error; end
    class PortExhaustedError < Error; end
    class HealthCheckError < Error; end

    TunnelDefinition = Struct.new(:session_token, :tunnel_port, :app_port, keyword_init: true) do
      def initialize(session_token:, tunnel_port:, app_port:)
        super(
          session_token: session_token.to_s,
          tunnel_port: Integer(tunnel_port),
          app_port: app_port.nil? ? nil : Integer(app_port)
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

    class << self
      def configure!(port_range:, server_port:, server_bind_host:, shared_token:)
        range = parse_port_range(port_range)

        Rails.application.config.x.preview_tunnel = {
          port_range: range,
          server_port: Integer(server_port),
          server_bind_host: server_bind_host.to_s,
          shared_token: shared_token.to_s
        }
      end

      def allocate_port(key:)
        normalized_key = key.to_s

        with_reservation_lock do
          sync_active_reservations!(range: port_range)
          prune_stale_reservations!(range: port_range)

          existing_port = PreviewTunnelPortReservation.where(reservation_key: normalized_key).pick(:tunnel_port)
          return existing_port if existing_port.present? && port_range.cover?(existing_port)

          PreviewTunnelPortReservation.where(reservation_key: normalized_key).delete_all if existing_port.present?

          reserved_ports = PreviewTunnelPortReservation.where(tunnel_port: port_range).pluck(:tunnel_port).to_set
          port = port_range.find { |candidate| !reserved_ports.include?(candidate) }
          raise PortExhaustedError, "No preview tunnel ports available in #{port_range.begin}-#{port_range.end}" if port.nil?

          PreviewTunnelPortReservation.create!(reservation_key: normalized_key, tunnel_port: port)
          port
        end
      end

      def release_port(key: nil, port: nil)
        with_reservation_lock do
          if key.present?
            reservation = PreviewTunnelPortReservation.find_by(reservation_key: key.to_s)
            return unless reservation

            reservation.destroy!
            return reservation.tunnel_port
          end

          if port.present?
            reservation = PreviewTunnelPortReservation.find_by(tunnel_port: Integer(port))
            return unless reservation

            reservation.destroy!
            return reservation.tunnel_port
          end

          raise ArgumentError, "key or port is required"
        end
      end

      def prune_stale_reservations!(range:, backend: Containers.backend, stale_before: DEFAULT_STALE_RESERVATION_GRACE_PERIOD.ago)
        active_allocations = active_tunnel_allocations(range:, backend:)

        PreviewTunnelPortReservation.where(tunnel_port: range)
          .where("updated_at < ?", stale_before)
          .find_each do |reservation|
            next if active_allocations[reservation.reservation_key] == reservation.tunnel_port

            reservation.destroy!
          end
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

      def port_range
        config.fetch(:port_range)
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

      def active_server_config_toml(backend: Containers.backend)
        server_config_toml(bindings: active_server_bindings(backend:))
      end

      def client_config(tunnel:, backend:, restricted:)
        definition = normalize_tunnel_definition(tunnel)
        raise ConfigurationError, "Preview tunnel app port is missing" if definition.app_port.blank?

        remote_destination = client_remote_destination(backend:, restricted:)

        [
          "[client]",
          %(remote_addr = "#{remote_destination.fetch(:host)}:#{remote_destination.fetch(:port)}"),
          %(default_token = "#{toml_string(shared_token)}"),
          "",
          "[client.transport]",
          'type = "noise"',
          "",
          "[client.services.#{definition.service_name}]",
          %(local_addr = "#{DEFAULT_LOCAL_APP_HOST}:#{definition.app_port}")
        ].join("\n") + "\n"
      end

      def wait_until_ready!(port:, host: DEFAULT_LOCAL_APP_HOST, path: "/", timeout_seconds: DEFAULT_HEALTH_CHECK_TIMEOUT_SECONDS)
        uri = URI.parse("http://#{host}:#{Integer(port)}#{normalize_health_check_path(path)}")

        Timeout.timeout(timeout_seconds, HealthCheckError, "Timed out waiting for preview tunnel #{uri}") do
          loop do
            response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) do |http|
              http.get(uri.request_uri)
            end

            return true if response.code.to_i < 500

            sleep HEALTH_CHECK_POLL_INTERVAL_SECONDS
          rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, EOFError, IOError, Net::OpenTimeout, Net::ReadTimeout, SocketError
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

      # Derives live service bindings from the backend abstraction rather than
      # Docker-specific container filters, so a remote/non-Docker backend can
      # supply preview containers without a local Docker socket.
      # @spec LIVE-PREVIEW-008
      def active_server_bindings(backend: Containers.backend)
        list_preview_containers(backend:).filter_map do |container|
          build_active_binding(container)
        end.sort_by(&:tunnel_port)
      end

      def active_tunnels(backend: Containers.backend)
        list_preview_containers(backend:).filter_map do |container|
          build_active_tunnel(container)
        end.sort_by(&:tunnel_port)
      end

      def client_remote_destination(backend:, restricted:)
        proxy_url = Containers::ProxyUrl.resolve(backend:, restricted:)
        uri = URI.parse(proxy_url)
        raise ConfigurationError, "Preview tunnel proxy URL is missing a host" if uri.host.blank?

        { host: uri.host, port: server_port }
      rescue URI::InvalidURIError => e
        raise ConfigurationError, "Invalid preview tunnel proxy URL: #{e.message}"
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

      def active_tunnel_allocations(range:, backend: Containers.backend)
        active_tunnels(backend:).each_with_object({}) do |tunnel, allocations|
          next unless range.cover?(tunnel.tunnel_port)

          allocations[tunnel.session_token] = tunnel.tunnel_port
        end
      end

      def sync_active_reservations!(range:, backend: Containers.backend)
        active_tunnel_allocations(range:, backend:).each do |reservation_key, tunnel_port|
          reservation = PreviewTunnelPortReservation.find_or_initialize_by(reservation_key:)
          next if reservation.persisted? && reservation.tunnel_port == tunnel_port

          PreviewTunnelPortReservation.where(tunnel_port: tunnel_port).where.not(reservation_key:).delete_all
          reservation.update!(tunnel_port:)
        end
      end

      def with_reservation_lock
        connection.execute("SELECT pg_advisory_lock(#{RESERVATION_LOCK_KEY})")
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{RESERVATION_LOCK_KEY})")
      end

      def connection
        ActiveRecord::Base.connection
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

      def toml_string(value)
        value.to_s.gsub("\\", "\\\\").gsub('"', '\"')
      end

      def normalize_health_check_path(path)
        normalized_path = path.to_s.presence || "/"
        normalized_path.start_with?("/") ? normalized_path : "/#{normalized_path}"
      end

      def list_preview_containers(backend:)
        backend.list_preview_containers
      end

      def build_active_tunnel(container)
        return unless preview_container_running?(container)

        labels = preview_container_labels(container)
        session_token = labels[PREVIEW_SESSION_TOKEN_LABEL].presence
        tunnel_port = labels[PREVIEW_TUNNEL_PORT_LABEL].presence
        return if session_token.blank? || tunnel_port.blank?

        TunnelDefinition.new(session_token: session_token, tunnel_port: tunnel_port, app_port: 0)
      rescue ArgumentError
        nil
      end

      def build_active_binding(container)
        return unless preview_container_running?(container)

        labels = preview_container_labels(container)
        session_token = labels[PREVIEW_SESSION_TOKEN_LABEL].presence
        service_name = labels[PREVIEW_SERVICE_NAME_LABEL].presence || "preview-#{session_token}"
        tunnel_port = labels[PREVIEW_TUNNEL_PORT_LABEL].presence
        return if session_token.blank? || tunnel_port.blank?

        ServerBinding.new(service_name: service_name, tunnel_port: tunnel_port)
      rescue ArgumentError
        nil
      end

      def preview_container_running?(container)
        state = container.info["State"] || {}
        state["Running"] == true || state["Status"] == "running"
      end

      def preview_container_labels(container)
        container.info.dig("Config", "Labels").presence || container.info["Labels"] || {}
      end
    end

    attr_reader :preview_session, :backend, :logger, :token

    def initialize(preview_session: nil, backend: Containers.backend, logger: Rails.logger, token: nil)
      @preview_session = preview_session
      @backend = backend
      @logger = logger
      @token = token.presence || preview_session_token || self.class.shared_token
      @allocation_key = build_allocation_key
      @allocated_port = nil
    end

    def allocate_port!
      return @allocated_port if @allocated_port.present?

      @allocated_port = self.class.allocate_port(key: @allocation_key)
      persist_preview_session!(tunnel_port: @allocated_port) if preview_session_tunnel_port != @allocated_port
      @allocated_port
    rescue StandardError
      self.class.release_port(key: @allocation_key) if @allocated_port.present?
      @allocated_port = nil
      raise
    end

    def release_port!
      reserved_port = @allocated_port.presence || preview_session_tunnel_port
      return if reserved_port.blank?

      begin
        persist_preview_session!(tunnel_port: nil)
      ensure
        self.class.release_port(key: @allocation_key, port: reserved_port)
        @allocated_port = nil
      end
    end

    def client_config(local_port:, remote_port: allocate_port!)
      self.class.client_config(
        tunnel: {
          session_token: tunnel_session_token,
          tunnel_port: remote_port,
          app_port: local_port
        },
        backend: backend,
        restricted: true
      )
    end

    def start_client!(container_service:, local_port:, remote_port: allocate_port!)
      config = client_config(local_port:, remote_port:)
      command = <<~SH
        set -e
        mkdir -p tmp
        cat > #{Shellwords.escape(CLIENT_CONFIG_PATH)} <<'TOML'
        #{config}
        TOML
        rathole --client #{Shellwords.escape(CLIENT_CONFIG_PATH)} > #{Shellwords.escape(CLIENT_LOG_PATH)} 2>&1 &
        echo $! > #{Shellwords.escape(CLIENT_PID_PATH)}
      SH

      container_service.execute(command, timeout: 30, stream: false)
    rescue Containers::Provision::ExecutionError => e
      raise Error, "failed to start rathole client: #{e.message}"
    end

    def stop_client!(container_service:)
      command = <<~SH
        if [ -f #{Shellwords.escape(CLIENT_PID_PATH)} ]; then
          kill "$(cat #{Shellwords.escape(CLIENT_PID_PATH)})" 2>/dev/null || true
          rm -f #{Shellwords.escape(CLIENT_PID_PATH)}
        fi
      SH

      container_service.execute(command, timeout: 10, stream: false)
    rescue Containers::Provision::ExecutionError
      nil
    end

    def wait_until_healthy!(port:, path:, timeout_seconds:)
      self.class.wait_until_ready!(
        port: port,
        path: path,
        timeout_seconds: timeout_seconds
      )
    end

    private

    def preview_session_token
      return unless preview_session&.respond_to?(:token)

      preview_session.token
    end

    def preview_session_tunnel_port
      return unless preview_session&.respond_to?(:tunnel_port)

      preview_session.tunnel_port
    end

    def persist_preview_session!(attributes)
      return unless preview_session&.respond_to?(:update!)

      preview_session.update!(attributes)
    end

    def build_allocation_key
      session_id = preview_session.id if preview_session&.respond_to?(:id)
      return "preview_session:#{session_id}" if session_id.present?

      tunnel_session_token
    end

    def tunnel_session_token
      preview_session_token.presence || "preview-tunnel-#{Process.pid}-#{SecureRandom.hex(6)}"
    end
  end
end
