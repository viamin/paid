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
