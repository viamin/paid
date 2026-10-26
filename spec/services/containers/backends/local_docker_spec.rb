# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::LocalDocker, :no_db do
  subject(:backend) { described_class.new }

  let(:container) { instance_double(Docker::Container) }
  let(:network) { instance_double(Docker::Network) }
  let(:volume) { instance_double(Docker::Volume) }

  # @spec CONTAINER-RUNTIME-049
  describe "local host memory evidence" do
    before do
      allow(Docker).to receive_messages(info: { "MemTotal" => 16_384 }, url: "unix:///var/run/docker.sock")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal: 16 kB\nMemAvailable: 3 kB\n")
    end

    it "includes available VM memory when host and daemon totals match" do
      expect(backend.system_info).to include("PaidHostMemAvailable" => 3_072)
    end

    it "does not substitute the control plane's memory for a different host" do
      allow(Docker).to receive(:info).and_return("MemTotal" => 32_768)
      expect(backend.system_info).not_to have_key("PaidHostMemAvailable")
    end

    it "preserves Docker capacity when procfs is unavailable" do
      allow(File).to receive(:read).with("/proc/meminfo").and_raise(Errno::ENOENT)
      expect(backend.system_info).to eq("MemTotal" => 16_384)
    end

    it "ignores local host memory for a TCP Docker endpoint" do
      allow(Docker).to receive(:url).and_return("tcp://another-host:2376")
      expect(backend.system_info).not_to have_key("PaidHostMemAvailable")
    end

    it "does not invent available memory when the kernel field is missing" do
      allow(File).to receive(:read).with("/proc/meminfo").and_return("MemTotal: 16 kB\n")
      expect(backend.system_info).not_to have_key("PaidHostMemAvailable")
    end

    it "does not hide a Docker socket error as an empty successful system-info response" do
      allow(Docker).to receive(:info).and_raise(Errno::ENOENT)
      expect { backend.system_info }.to raise_error(Errno::ENOENT)
    end

    it "keeps valid Docker evidence when optional host-memory IO fails" do
      allow(File).to receive(:read).with("/proc/meminfo").and_raise(Errno::EIO)
      expect(backend.system_info).to eq("MemTotal" => 16_384)
    end
  end

  it "reports the local backend identifier" do
    expect(backend.identifier).to eq("local")
  end

  it "preserves a configured host identifier" do
    backend = described_class.new(identifier: "qnap")

    expect(backend.identifier).to eq("qnap")
    expect(backend.all_host_identifiers).to eq([ "qnap" ])
    expect(backend.container_host_for(container)).to eq("qnap")
  end

  it "delegates container creation and lookup to docker-api" do
    allow(Docker::Container).to receive(:create).and_return(container)
    allow(Docker::Container).to receive(:get).with("abc123").and_return(container)

    expect(backend.create_container("Image" => "paid-agent:latest")).to eq(container)
    expect(backend.get_container("abc123")).to eq(container)
  end

  it "delegates network and volume access to docker-api" do
    allow(Docker::Network).to receive(:get).with("paid_agent").and_return(network)
    allow(Docker::Volume).to receive(:get).with("paid-workspace-1").and_return(volume)

    expect(backend.get_network("paid_agent")).to eq(network)
    expect(backend.get_volume("paid-workspace-1")).to eq(volume)
  end

  it "delegates volume deletion to docker-api" do
    allow(volume).to receive(:remove).with(force: true).and_return(true)

    expect(backend.delete_volume(volume, force: true)).to be(true)
  end

  it "accepts the legacy positional options hash when creating volumes" do
    allow(Docker::Volume).to receive(:create) do |name, options|
      expect(name).to eq("paid-workspace-1")
      expect(options).to eq("Labels" => { "paid.managed" => "true" })
      volume
    end

    expect(backend.create_volume("paid-workspace-1", "Labels" => { "paid.managed" => "true" })).to eq(volume)
  end

  it "builds an image from a Dockerfile string via docker-api's string-body build API" do
    built_image = instance_double(Docker::Image)
    allow(Docker::Image).to receive(:build).with("FROM scratch", { t: "paid-agent:go" }).and_return(built_image)

    expect(backend.build_image("FROM scratch", { t: "paid-agent:go" })).to eq(built_image)
  end

  it "checks image usage via the ancestor container-list filter" do
    allow(Docker::Container).to receive(:all)
      .with(filters: { ancestor: [ "paid-agent:go-node" ] }.to_json)
      .and_return([ container ])

    expect(backend.image_in_use?("paid-agent:go-node")).to be(true)
  end
end
