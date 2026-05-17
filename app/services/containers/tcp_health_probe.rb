# frozen_string_literal: true

require "docker-api"
require "socket"

module Containers
  class TcpHealthProbe
    class << self
      def open?(backend:, container:, host:, port:, fallback_on_missing_tools: true)
        backend.remote? ? remote_port_open?(backend: backend, container: container, port: port, fallback_on_missing_tools: fallback_on_missing_tools) : local_port_open?(host, port)
      end

      private

      def remote_port_open?(backend:, container:, port:, fallback_on_missing_tools: true)
        return false if container.blank?

        _stdout, _stderr, status = backend.exec_in_container(container, [ "sh", "-c", probe_script(port) ])
        # Exit 127 means none of the probe tools (nc, bash, ruby, python, node)
        # were found in the container. When fallback_on_missing_tools is true,
        # assume healthy to avoid blocking minimal/distroless images. When false
        # (e.g. service containers like postgres/redis that should have tools),
        # report unhealthy so the caller keeps waiting.
        return fallback_on_missing_tools if status == 127

        status.zero?
      rescue Docker::Error::DockerError, Excon::Error
        false
      end

      def local_port_open?(host, port)
        socket = Socket.tcp(host, port, connect_timeout: 1)
        socket.close
        true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError
        false
      end

      def probe_script(port)
        port = Integer(port)
        raise ArgumentError, "Invalid probe port: #{port}" unless port.between?(1, 65_535)

        <<~SH
          set -eu
          if command -v nc >/dev/null 2>&1; then
            exec nc -z 127.0.0.1 #{port}
          fi
          if command -v bash >/dev/null 2>&1; then
            exec bash -c "exec 3<>/dev/tcp/127.0.0.1/#{port}"
          fi
          if command -v ruby >/dev/null 2>&1; then
            exec ruby -rsocket -e "Socket.tcp('127.0.0.1', #{port}, connect_timeout: 1).close"
          fi
          if command -v python3 >/dev/null 2>&1; then
            exec python3 -c "import socket; s=socket.create_connection(('127.0.0.1', #{port}), 1); s.close()"
          fi
          if command -v python >/dev/null 2>&1; then
            exec python -c "import socket; s=socket.create_connection(('127.0.0.1', #{port}), 1); s.close()"
          fi
          if command -v node >/dev/null 2>&1; then
            exec node -e "const net=require('net'); const s=net.createConnection({host:'127.0.0.1', port:#{port}}); s.on('connect',()=>{s.end(); process.exit(0)}); s.on('error',()=>process.exit(1)); setTimeout(()=>process.exit(1), 1000);"
          fi
          exit 127
        SH
      rescue ArgumentError, TypeError
        raise ArgumentError, "Invalid probe port: #{port.inspect}"
      end
    end
  end
end
