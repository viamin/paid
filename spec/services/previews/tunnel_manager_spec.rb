# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::TunnelManager do
  def preview_container_info(session_token:, tunnel_port:, running: true, service_name: nil)
    labels = {
      described_class::PREVIEW_TUNNEL_LABEL => "true",
      described_class::PREVIEW_SESSION_TOKEN_LABEL => session_token,
      described_class::PREVIEW_TUNNEL_PORT_LABEL => tunnel_port.to_s
    }
    labels[described_class::PREVIEW_SERVICE_NAME_LABEL] = service_name if service_name

    {
      "State" => { "Running" => running },
      "Config" => { "Labels" => labels }
    }
  end

  let(:original_preview_tunnel_config) { Rails.application.config.x.preview_tunnel }
  let(:default_backend) { instance_double(Containers::Backends::Base, identifier: "local", list_containers: []) }

  before do
    allow(Containers).to receive(:backend).and_return(default_backend)
    allow(default_backend).to receive(:list_containers)
      .with(filters: { label: [ "#{described_class::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
      .and_return([])
    PreviewTunnelPortReservation.delete_all
    described_class.configure!(
      port_range: "8200-8202",
      server_port: 7000,
      server_bind_host: "0.0.0.0",
      shared_token: "paid-preview-test-token"
    )
  end

  after do
    Rails.application.config.x.preview_tunnel = original_preview_tunnel_config
    PreviewTunnelPortReservation.delete_all
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

    it "reclaims stale reservations that are no longer backed by a live preview container" do
      %w[stale-a stale-b stale-c].each.with_index(8200) do |key, port|
        reservation = PreviewTunnelPortReservation.create!(reservation_key: key, tunnel_port: port)
        reservation.update_columns(created_at: 20.minutes.ago, updated_at: 20.minutes.ago)
      end

      expect(described_class.allocate_port(key: "fresh-preview")).to eq(8200)
    end

    it "does not allocate or prune when the backend cannot be queried" do
      stale = PreviewTunnelPortReservation.create!(reservation_key: "stale-preview", tunnel_port: 8200)
      stale.update_columns(created_at: 20.minutes.ago, updated_at: 20.minutes.ago)

      backend = instance_double(Containers::Backends::Base, identifier: "local")
      allow(Containers).to receive(:backend).and_return(backend)
      allow(backend).to receive(:list_containers)
        .with(filters: { label: [ "#{described_class::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
        .and_raise(Docker::Error::TimeoutError, "docker unavailable")

      expect {
        described_class.allocate_port(key: "fresh-preview")
      }.to raise_error(Docker::Error::TimeoutError, "docker unavailable")

      expect(PreviewTunnelPortReservation.exists?(stale.id)).to be(true)
      expect(PreviewTunnelPortReservation.exists?(reservation_key: "fresh-preview")).to be(false)
    end
  end

  describe ".prune_stale_reservations!" do
    it "keeps fresh and active reservations while deleting stale orphaned rows" do
      stale = PreviewTunnelPortReservation.create!(reservation_key: "stale-preview", tunnel_port: 8200)
      fresh = PreviewTunnelPortReservation.create!(reservation_key: "fresh-preview", tunnel_port: 8201)
      active = PreviewTunnelPortReservation.create!(reservation_key: "active-preview", tunnel_port: 8202)
      stale.update_columns(created_at: 20.minutes.ago, updated_at: 20.minutes.ago)
      active.update_columns(created_at: 20.minutes.ago, updated_at: 20.minutes.ago)

      backend = instance_double(Containers::Backends::Base, identifier: "local")
      preview_container = instance_double(Docker::Container, info: preview_container_info(session_token: "active-preview", tunnel_port: 8202))
      allow(backend).to receive(:list_containers)
        .with(filters: { label: [ "#{described_class::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
        .and_return([ preview_container ])

      described_class.prune_stale_reservations!(
        range: described_class.port_range,
        backend:,
        stale_before: 15.minutes.ago
      )

      expect(PreviewTunnelPortReservation.exists?(stale.id)).to be(false)
      expect(PreviewTunnelPortReservation.exists?(fresh.id)).to be(true)
      expect(PreviewTunnelPortReservation.exists?(active.id)).to be(true)
    end

    it "propagates backend lookup failures without deleting stale reservations" do
      stale = PreviewTunnelPortReservation.create!(reservation_key: "stale-preview", tunnel_port: 8200)
      stale.update_columns(created_at: 20.minutes.ago, updated_at: 20.minutes.ago)

      backend = instance_double(Containers::Backends::Base, identifier: "local")
      allow(backend).to receive(:list_containers)
        .with(filters: { label: [ "#{described_class::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
        .and_raise(Docker::Error::TimeoutError, "docker unavailable")

      expect {
        described_class.prune_stale_reservations!(
          range: described_class.port_range,
          backend:,
          stale_before: 15.minutes.ago
        )
      }.to raise_error(Docker::Error::TimeoutError, "docker unavailable")

      expect(PreviewTunnelPortReservation.exists?(stale.id)).to be(true)
    end
  end

  describe ".configure!" do
    it "preserves existing reservations when the range is unchanged" do
      first = described_class.allocate_port(key: "session-a")

      described_class.configure!(
        port_range: "8200-8202",
        server_port: 7001,
        server_bind_host: "127.0.0.1",
        shared_token: "replacement-token"
      )

      expect(described_class.allocate_port(key: "session-a")).to eq(first)
      expect(described_class.server_port).to eq(7001)
      expect(described_class.shared_token).to eq("replacement-token")
    end

    it "seeds reservations from active preview containers when allocating" do
      backend = instance_double(Containers::Backends::Base, identifier: "local")
      preview_container = instance_double(Docker::Container, info: preview_container_info(session_token: "active-preview", tunnel_port: 8201))
      allow(Containers).to receive(:backend).and_return(backend)
      allow(backend).to receive(:list_containers)
        .with(filters: { label: [ "#{described_class::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
        .and_return([ preview_container ])

      described_class.configure!(
        port_range: "8200-8202",
        server_port: 7000,
        server_bind_host: "0.0.0.0",
        shared_token: "paid-preview-test-token"
      )

      expect(described_class.allocate_port(key: "active-preview")).to eq(8201)
      expect(described_class.allocate_port(key: "new-preview")).to eq(8200)
    end

    it "reconciles conflicting reservations in favor of active preview containers" do
      PreviewTunnelPortReservation.create!(reservation_key: "stale-preview", tunnel_port: 8201)
      backend = instance_double(Containers::Backends::Base, identifier: "local")
      preview_container = instance_double(Docker::Container, info: preview_container_info(session_token: "active-preview", tunnel_port: 8201))
      allow(Containers).to receive(:backend).and_return(backend)
      allow(backend).to receive(:list_containers)
        .with(filters: { label: [ "#{described_class::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
        .and_return([ preview_container ])

      expect(described_class.allocate_port(key: "active-preview")).to eq(8201)
      expect(described_class.allocate_port(key: "fresh-preview")).to eq(8200)
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

  describe ".active_server_config_toml" do
    it "renders bindings from active preview containers" do
      backend = instance_double(Containers::Backends::Base, identifier: "local")
      preview_container = instance_double(Docker::Container, info: preview_container_info(session_token: "abc123", tunnel_port: 8201))
      allow(backend).to receive(:list_containers)
        .with(filters: { label: [ "#{described_class::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
        .and_return([ preview_container ])

      config = described_class.active_server_config_toml(backend:)

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
      expect(config).not_to include("remote_port")
    end
  end

  describe ".wait_until_ready!" do
    it "returns when the local tunnel serves an HTTP response" do
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        client = server.accept
        client.gets("\r\n")
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        client.close
      ensure
        server.close
      end

      expect(described_class.wait_until_ready!(host: "127.0.0.1", port: server.addr[1], path: "/ready", timeout_seconds: 1)).to be(true)

      thread.join
    end

    it "does not treat a bare TCP listener as a ready tunnel" do
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          client = server.accept
          client.close
        end
      rescue IOError, Errno::EBADF
      ensure
        server.close
      end

      expect {
        described_class.wait_until_ready!(host: "127.0.0.1", port: server.addr[1], timeout_seconds: 1)
      }.to raise_error(described_class::HealthCheckError)

      server.close
      thread.join
    end
  end
end
