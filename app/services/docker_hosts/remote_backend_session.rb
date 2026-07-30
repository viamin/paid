# frozen_string_literal: true

require "tempfile"

module DockerHosts
  class RemoteBackendSession
    def self.with_backend(host)
      new(host).with_backend { |backend| yield backend }
    end

    def initialize(host)
      @host = host
      @tempfiles = []
    end

    def with_backend
      raise ArgumentError, "Remote Docker setup requires a remote host" unless host.remote?
      raise ArgumentError, "Client TLS material is incomplete" unless host.client_tls_material_present?

      backend = Containers::Backends::RemoteDocker.new(
        host: host.endpoint,
        identifier: host.identifier,
        proxy_external_url: host.callback_url,
        tls_config: {
          client_cert: write_tempfile("client-cert", host.client_certificate_pem),
          client_key: write_tempfile("client-key", host.client_private_key_pem, mode: 0o600),
          ssl_ca_file: write_tempfile("ca", host.client_ca_pem)
        }
      )

      yield backend
    ensure
      cleanup!
    end

    private

    attr_reader :host, :tempfiles

    def write_tempfile(prefix, contents, mode: 0o644)
      tempfile = Tempfile.new([ "#{host.identifier}-#{prefix}", ".pem" ])
      tempfile.write(contents.to_s)
      tempfile.flush
      File.chmod(mode, tempfile.path)
      tempfiles << tempfile
      tempfile.path
    end

    def cleanup!
      tempfiles.each(&:close!)
    end
  end
end
