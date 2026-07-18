# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::TunnelManager do
  let(:backend) { double(remote?: false) }
  let(:preview_session) { double(tunnel_port: 8201, token: "preview-token") }

  describe "#client_config" do
    it "uses the local proxy host for local backends" do
      manager = described_class.new(backend:, token: "preview-token")

      config = manager.client_config(local_port: 4000, remote_port: 8201)

      expect(config).to include('remote_addr = "paid-proxy:7000"')
      expect(config).to include('default_token = "preview-token"')
      expect(config).to include('local_addr = "127.0.0.1:4000"')
      expect(config).to include("remote_port = 8201")
    end

    it "uses the external proxy host for remote backends" do
      remote_backend = double(remote?: true)
      manager = described_class.new(backend: remote_backend, token: "preview-token")
      allow(Containers::ProxyUrl).to receive(:resolve).with(backend: remote_backend, restricted: true)
        .and_return("https://proxy.example.test:3443")

      config = manager.client_config(local_port: 4000, remote_port: 8201)

      expect(config).to include('remote_addr = "proxy.example.test:7000"')
    end
  end

  describe "#start_client!" do
    it "backgrounds rathole directly so the PID file captures the real process" do
      manager = described_class.new(backend:, token: "preview-token")
      executed = []
      container_service = instance_double(Containers::Provision)
      allow(container_service).to receive(:execute) { |command, **| executed << command }

      manager.start_client!(container_service:, local_port: 4000, remote_port: 8201)

      command = executed.join
      expect(command).to include("echo $! >")
      rathole_line = command.lines.find { |line| line.include?("rathole ") }
      # Backgrounding rathole directly (rather than inside a subshell) keeps $!
      # pointed at the real process so stop_client! can kill it. A subshell
      # wrapper like `(rathole ... &)` clears $! in the parent shell and leaves
      # the PID file empty, leaking the tunnel client and its port.
      expect(rathole_line).to end_with("&\n")
      expect(command).not_to match(/\(.*rathole.*&\)/)
    end
  end

  describe "#stop_client!" do
    it "kills the process whose PID is recorded in the client PID file" do
      manager = described_class.new(backend:, token: "preview-token")
      executed = []
      container_service = instance_double(Containers::Provision)
      allow(container_service).to receive(:execute) { |command, **| executed << command }

      manager.stop_client!(container_service:)

      expect(executed.join).to include('kill "$(cat tmp/paid-preview-rathole.pid)"')
    end
  end

  describe ".reserve_port!" do
    around do |example|
      described_class.release_port(8298)
      described_class.release_port(8299)
      example.run
    ensure
      described_class.release_port(8298)
      described_class.release_port(8299)
    end

    it "reserves and releases a port from the preview pool" do
      port = described_class.reserve_port!(range: 8298..8299)

      expect(port).to be_between(8298, 8299)
      expect(PreviewTunnelReservation.find_by(port: port)).to be_present

      described_class.release_port(port)

      expect { described_class.reserve_port!(range: port..port) }.not_to raise_error
      described_class.release_port(port)
    end

    it "skips ports that are already reserved in the database" do
      PreviewTunnelReservation.create!(port: 8298)

      expect(described_class.reserve_port!(range: 8298..8299)).to eq(8299)
    end
  end

  describe "#allocate_port!" do
    around do |example|
      described_class.release_port(8201)
      described_class.release_port(8299)
      example.run
    ensure
      described_class.release_port(8201)
      described_class.release_port(8299)
    end

    it "re-reserves a persisted port when the preview session still points at it" do
      manager = described_class.new(backend:, preview_session:)
      allow(preview_session).to receive(:update!)

      expect(manager.allocate_port!).to eq(8201)
      expect(preview_session).not_to have_received(:update!)
      expect(PreviewTunnelReservation.find_by(port: 8201)).to be_present
    end

    it "allocates a new port when the persisted port is already reserved elsewhere" do
      PreviewTunnelReservation.create!(port: 8201)
      manager = described_class.new(backend:, preview_session:)
      allow(preview_session).to receive(:update!)

      allocated_port = manager.allocate_port!

      expect(allocated_port).not_to eq(8201)
      expect(preview_session).to have_received(:update!).with(tunnel_port: allocated_port)
      expect(PreviewTunnelReservation.find_by(port: 8201)).to be_present
      expect(PreviewTunnelReservation.find_by(port: allocated_port)).to be_present
    end
  end

  describe "#release_port!" do
    it "releases the reserved port even if preview session persistence fails" do
      PreviewTunnelReservation.create!(port: 8201)
      manager = described_class.new(backend:, preview_session:)
      manager.instance_variable_set(:@allocated_port, 8201)
      allow(preview_session).to receive(:update!).and_raise("write failed")
      allow(described_class).to receive(:release_port).and_call_original

      expect { manager.release_port! }.to raise_error("write failed")
      expect(described_class).to have_received(:release_port).with(8201)
      expect(PreviewTunnelReservation.find_by(port: 8201)).to be_nil
    end
  end
end
