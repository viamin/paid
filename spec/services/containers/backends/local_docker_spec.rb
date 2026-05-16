# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::LocalDocker, :no_db do
  subject(:backend) { described_class.new }

  let(:container) { instance_double(Docker::Container) }
  let(:network) { instance_double(Docker::Network) }
  let(:volume) { instance_double(Docker::Volume) }

  it "reports the local backend identifier" do
    expect(backend.identifier).to eq("local")
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
end
