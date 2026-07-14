# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::TunnelManager do
  let(:original_preview_tunnel_config) { Rails.application.config.x.preview_tunnel }
  let(:original_preview_tunnel_port_pool) { Rails.application.config.x.preview_tunnel_port_pool }

  before do
    described_class.configure!(
      port_range: "8200-8202",
      server_port: 7000,
      server_bind_host: "0.0.0.0",
      shared_token: "paid-preview-test-token"
    )
  end

  after do
    Rails.application.config.x.preview_tunnel = original_preview_tunnel_config
    Rails.application.config.x.preview_tunnel_port_pool = original_preview_tunnel_port_pool
  end

  describe ".parse_port_range" do
    it "parses an inclusive port range" do
      expect(described_class.parse_port_range("8200-8299")).to eq(8200..8299)
    end

    it "rejects malformed ranges" do
      expect {
        described_class.parse_port_range("8299:8200")
      }.to raise_error(described_class::ConfigurationError, /Invalid PREVIEW_PORT_RANGE/)
    end
  end

  describe ".allocate_port / .release_port" do
    it "allocates stable ports per key and reuses released ports" do
      first = described_class.allocate_port(key: "session-a")
      second = described_class.allocate_port(key: "session-b")

      expect(first).to eq(8200)
      expect(second).to eq(8201)
      expect(described_class.allocate_port(key: "session-a")).to eq(first)

      described_class.release_port(key: "session-a")

      expect(described_class.allocate_port(key: "session-c")).to eq(8200)
    end

    it "raises when the pool is exhausted" do
      %w[a b c].each { |key| described_class.allocate_port(key:) }

      expect {
        described_class.allocate_port(key: "d")
      }.to raise_error(described_class::PortExhaustedError, /No preview tunnel ports available/)
    end
  end

  describe ".server_config_toml" do
    it "renders a noise-encrypted server config with explicit service bindings" do
      config = described_class.server_config_toml(bindings: [
        { service_name: "preview-abc123", tunnel_port: 8201 }
      ])

      expect(config).to include("[server]")
      expect(config).to include('bind_addr = "0.0.0.0:7000"')
      expect(config).to include('default_token = "paid-preview-test-token"')
      expect(config).to include("[server.transport]")
      expect(config).to include('type = "noise"')
      expect(config).to include("[server.services.preview-abc123]")
      expect(config).to include('bind_addr = "0.0.0.0:8201"')
    end
  end

  describe ".client_config" do
    let(:backend) { instance_double(Containers::Backends::Base, remote?: false) }

    before do
      allow(Containers::ProxyUrl).to receive(:resolve).with(backend:, restricted: true).and_return("http://paid-proxy:3000")
    end

    it "renders a noise-encrypted client config for the preview app port" do
      config = described_class.client_config(
        tunnel: { session_token: "abc123", tunnel_port: 8201, app_port: 4000 },
        backend: backend,
        restricted: true
      )

      expect(config).to include("[client]")
      expect(config).to include('remote_addr = "paid-proxy:7000"')
      expect(config).to include('default_token = "paid-preview-test-token"')
      expect(config).to include("[client.transport]")
      expect(config).to include('type = "noise"')
      expect(config).to include("[client.services.preview-abc123]")
      expect(config).to include('local_addr = "127.0.0.1:4000"')
      expect(config).to include("remote_port = 8201")
    end
  end

  describe ".wait_until_ready!" do
    it "returns when the local tunnel port accepts connections" do
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        client = server.accept
        client.close
      ensure
        server.close
      end

      expect(described_class.wait_until_ready!(host: "127.0.0.1", port: server.addr[1], timeout_seconds: 1)).to be(true)

      thread.join
    end
  end
end
