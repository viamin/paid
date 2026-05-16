# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::RemoteDocker, :no_db do
  subject(:backend) do
    described_class.new(
      host: "worker-1.internal",
      identifier: "worker-1",
      tls_config: tls_config
    )
  end

  let(:connection) { instance_double(Docker::Connection) }
  let(:container) { instance_double(Docker::Container) }
  let(:network) { instance_double(Docker::Network) }
  let(:volume) { instance_double(Docker::Volume) }
  let(:image) { instance_double(Docker::Image) }

  let(:tls_config) do
    {
      client_cert: "/etc/paid/certs/client-cert.pem",
      client_key: "/etc/paid/certs/client-key.pem",
      ssl_ca_file: "/etc/paid/certs/ca.pem"
    }
  end

  before do
    allow(Docker::Connection).to receive(:new).and_return(connection)
  end

  it "reports a remote backend identifier" do
    expect(backend.identifier).to eq("worker-1")
    expect(backend).to be_remote
  end

  it "creates a tls docker connection for the remote host" do
    backend

    expect(Docker::Connection).to have_received(:new).with(
      "tcp://worker-1.internal:2376",
      hash_including(
        client_cert: tls_config[:client_cert],
        client_key: tls_config[:client_key],
        ssl_ca_file: tls_config[:ssl_ca_file],
        scheme: "https"
      )
    )
  end

  it "delegates ping through the connection" do
    allow(Docker).to receive(:ping).with(connection).and_return("OK")

    expect(backend.ping).to eq("OK")
  end

  it "delegates container operations through the remote connection" do
    allow(Docker::Container).to receive(:create).with({ "Image" => "paid-agent:latest" }, connection).and_return(container)
    allow(Docker::Container).to receive(:get).with("abc123", {}, connection).and_return(container)
    allow(Docker::Container).to receive(:all).with({ all: true }, connection).and_return([ container ])

    expect(backend.create_container("Image" => "paid-agent:latest")).to eq(container)
    expect(backend.get_container("abc123")).to eq(container)
    expect(backend.list_containers(all: true)).to eq([ container ])
  end

  it "delegates network, image, and volume access through the remote connection" do
    allow(Docker::Network).to receive(:get).with("paid_agent", {}, connection).and_return(network)
    allow(Docker::Network).to receive(:create).with("paid_agent", { "Driver" => "bridge" }, connection).and_return(network)
    allow(Docker::Image).to receive(:create).with({ "fromImage" => "paid-agent:latest" }, nil, connection).and_return(image)
    allow(Docker::Volume).to receive(:get).with("paid-workspace-1", connection).and_return(volume)
    allow(Docker::Volume).to receive(:create).with("paid-workspace-1", { "Labels" => { "paid.managed" => "true" } }, connection).and_return(volume)
    allow(Docker::Volume).to receive(:all).with({}, connection).and_return([ volume ])

    expect(backend.get_network("paid_agent")).to eq(network)
    expect(backend.create_network("paid_agent", "Driver" => "bridge")).to eq(network)
    expect(backend.pull_image("fromImage" => "paid-agent:latest")).to eq(image)
    expect(backend.get_volume("paid-workspace-1")).to eq(volume)
    expect(backend.create_volume("paid-workspace-1", "Labels" => { "paid.managed" => "true" })).to eq(volume)
    expect(backend.list_volumes).to eq([ volume ])
  end

  it "requires mutual tls configuration" do
    expect {
      described_class.new(host: "worker-1.internal", tls_config: { client_cert: "/tmp/cert.pem" })
    }.to raise_error(ArgumentError, /REMOTE_DOCKER_KEY, REMOTE_DOCKER_CA/)
  end

  describe ".from_env" do
    around do |example|
      original_env = ENV.to_h.slice(
        "REMOTE_DOCKER_HOST", "REMOTE_DOCKER_IDENTIFIER",
        "REMOTE_DOCKER_CERT", "REMOTE_DOCKER_KEY", "REMOTE_DOCKER_CA"
      )
      ENV["REMOTE_DOCKER_HOST"] = "worker-2.internal:2443"
      ENV["REMOTE_DOCKER_IDENTIFIER"] = "worker-2"
      ENV["REMOTE_DOCKER_CERT"] = "/certs/client.pem"
      ENV["REMOTE_DOCKER_KEY"] = "/certs/client-key.pem"
      ENV["REMOTE_DOCKER_CA"] = "/certs/ca.pem"
      example.run
    ensure
      original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    it "builds a backend from environment configuration" do
      backend = described_class.from_env

      expect(backend.identifier).to eq("worker-2")
      expect(backend.docker_url).to eq("tcp://worker-2.internal:2443")
    end
  end
end
