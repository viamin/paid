# frozen_string_literal: true

require "net/http"
require "securerandom"
require "shellwords"
require "socket"
require "uri"

module Previews
  class TunnelManager
    SERVER_PORT = 7000
    DEFAULT_PORT_RANGE = (8200..8299)
    CLIENT_CONFIG_PATH = "tmp/paid-preview-rathole.toml"
    CLIENT_LOG_PATH = "tmp/paid-preview-rathole.log"
    CLIENT_PID_PATH = "tmp/paid-preview-rathole.pid"
    DEFAULT_TOKEN = "paid-preview-development-token"
    HEALTH_CHECK_INTERVAL_SECONDS = 2
    LEGACY_STALE_RESERVATION_TTL = 15.minutes

    class Error < StandardError; end
    class PortExhaustedError < Error; end
    class HealthCheckError < Error; end

    class << self
      def reserve_port!(range: DEFAULT_PORT_RANGE, exclude: [], owner_key:, owner_pid: Process.pid)
        excluded_ports = Array(exclude).map(&:to_i)
        reclaim_stale_reservations!

        range.each do |candidate|
          next if excluded_ports.include?(candidate)
          next unless port_available?(candidate)

          return PreviewTunnelReservation.create!(
            port: candidate,
            owner_key: owner_key,
            owner_pid: owner_pid
          ).port
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
          next
        end

        raise PortExhaustedError, "no preview tunnel ports available in #{range.begin}-#{range.end}"
      end

      def reserve_specific_port(port, owner_key:, owner_pid: Process.pid)
        candidate = port.to_i
        return if candidate <= 0

        reclaim_stale_reservations!
        return unless port_available?(candidate)

        PreviewTunnelReservation.create!(
          port: candidate,
          owner_key: owner_key,
          owner_pid: owner_pid
        ).port
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        nil
      end

      def release_port(port)
        return if port.blank?

        PreviewTunnelReservation.find_by(port: port.to_i)&.destroy!
      end

      private

      def reclaim_stale_reservations!
        PreviewTunnelReservation.find_each do |reservation|
          next unless stale_reservation?(reservation)

          reservation.destroy!
        rescue ActiveRecord::RecordNotFound
          nil
        end
      end

      def stale_reservation?(reservation)
        if reservation.owner_pid.present?
          !process_alive?(reservation.owner_pid)
        else
          reservation.updated_at <= LEGACY_STALE_RESERVATION_TTL.ago
        end
      end

      def process_alive?(pid)
        Process.kill(0, Integer(pid))
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def port_available?(port)
        server = TCPServer.new("127.0.0.1", port)
        server.close
        true
      rescue Errno::EADDRINUSE, Errno::EACCES
        false
      end
    end

    attr_reader :preview_session, :backend, :logger, :token

    def initialize(preview_session: nil, backend: Containers.backend, logger: Rails.logger, token: nil)
      @preview_session = preview_session
      @backend = backend
      @logger = logger
      @token = token.presence || preview_session_token || DEFAULT_TOKEN
      @persisted_port = preview_session&.respond_to?(:tunnel_port) ? preview_session.tunnel_port : nil
      @allocated_port = nil
      @owner_key = build_owner_key
    end

    def allocate_port!
      return @allocated_port if @allocated_port.present?

      allocated_port = reserve_persisted_port || self.class.reserve_port!(
        exclude: @persisted_port,
        owner_key: @owner_key
      )
      persist_preview_session!(tunnel_port: allocated_port) if allocated_port != @persisted_port
      @allocated_port = allocated_port
    rescue StandardError
      self.class.release_port(allocated_port) if allocated_port.present?
      raise
    end

    def release_port!
      allocated_port = release_port_number
      return if allocated_port.blank?

      begin
        persist_preview_session!(tunnel_port: nil)
      ensure
        begin
          self.class.release_port(allocated_port)
        ensure
          @allocated_port = nil
          @persisted_port = nil
        end
      end
    end

    def client_config(local_port:, remote_port: allocate_port!)
      <<~TOML
        [client]
        remote_addr = "#{remote_addr}"
        default_token = "#{token}"

        [client.services.preview]
        local_addr = "127.0.0.1:#{Integer(local_port)}"
        remote_port = #{Integer(remote_port)}
      TOML
    end

    def start_client!(container_service:, local_port:, remote_port: allocate_port!)
      config = client_config(local_port:, remote_port:)
      command = <<~SH
        set -e
        mkdir -p tmp
        cat > #{Shellwords.escape(CLIENT_CONFIG_PATH)} <<'TOML'
        #{config}
        TOML
        rathole #{Shellwords.escape(CLIENT_CONFIG_PATH)} > #{Shellwords.escape(CLIENT_LOG_PATH)} 2>&1 &
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
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

      until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        if Containers::TcpHealthProbe.open?(backend:, container: nil, host: "127.0.0.1", port: port) &&
            forwarding_http?(port:, path:)
          return true
        end

        sleep HEALTH_CHECK_INTERVAL_SECONDS
      end

      raise HealthCheckError, "preview tunnel did not become healthy on port #{port}"
    end

    private

    def preview_session_token
      return unless preview_session&.respond_to?(:token)

      preview_session.token
    end

    def remote_addr
      if backend.remote?
        proxy_url = Containers::ProxyUrl.resolve(backend:, restricted: true)
        proxy_uri = URI.parse(proxy_url)
        return "#{proxy_uri.host}:#{SERVER_PORT}"
      end

      "paid-proxy:#{SERVER_PORT}"
    rescue URI::InvalidURIError => e
      raise Error, "invalid preview tunnel remote address: #{e.message}"
    end

    def forwarding_http?(port:, path:)
      http = Net::HTTP.new("127.0.0.1", port)
      http.open_timeout = 2
      http.read_timeout = 2
      response = http.get(path.presence || "/")
      response.code.to_i < 500
    rescue StandardError
      false
    end

    def persist_preview_session!(attributes)
      return unless preview_session&.respond_to?(:update!)

      preview_session.update!(attributes)
    end

    def reserve_persisted_port
      return if @persisted_port.blank?

      self.class.reserve_specific_port(@persisted_port, owner_key: @owner_key)
    end

    def release_port_number
      @allocated_port.presence || preview_session&.tunnel_port || @persisted_port
    end

    def build_owner_key
      session_id = preview_session.id if preview_session&.respond_to?(:id)
      return "preview_session:#{session_id}" if session_id.present?

      "preview_tunnel:#{Process.pid}:#{SecureRandom.hex(6)}"
    end
  end
end
