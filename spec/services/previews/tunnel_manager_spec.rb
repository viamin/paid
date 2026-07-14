# frozen_string_literal: true

require "rails_helper"

RSpec.describe Previews::TunnelManager do
  let(:backend) { double(remote?: false) }

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
    it "reserves and releases a port from the preview pool" do
      port = described_class.reserve_port!(range: 8298..8299)

      expect(port).to be_between(8298, 8299)

      described_class.release_port(port)

      expect { described_class.reserve_port!(range: port..port) }.not_to raise_error
      described_class.release_port(port)
    end
  end
end
