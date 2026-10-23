# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::PruneDockerDisk, :no_db do
  let(:connection) { instance_double(Docker::Connection, options: { socket: "/var/run/docker.sock" }) }
  let(:cutoff) { 7.days.ago.to_i }
  let(:old_image) { { "Id" => "sha256:old", "Created" => cutoff - 1, "Size" => 123, "RepoTags" => [ "unused:latest" ] } }
  let(:service) { described_class.new(connection: connection, protected_references: [ "custom:runtime" ]) }

  around { |example| travel_to(Time.current.change(usec: 0)) { example.run } }

  before do
    allow(connection).to receive(:get).with("/images/json").and_return([ old_image ].to_json)
    allow(connection).to receive(:get).with("/containers/json", all: true).and_return("[]")
    allow(connection).to receive(:get).with("/images/custom:runtime/json").and_return({ "Id" => "sha256:protected" }.to_json)
    allow(connection).to receive(:delete).with("/images/sha256:old", force: false, noprune: true).and_return("[]")
    allow(connection).to receive(:post).and_return({ "SpaceReclaimed" => 456 }.to_json)
  end

  # @spec DOCKER-DISK-CLEANUP-002 DOCKER-DISK-CLEANUP-004
  it "removes only the selected image without force or implicit parent pruning" do
    expect(service.call).to include(images_removed: 1, image_bytes_estimate: 123, cache_bytes_reclaimed: 456)
    expect(connection).to have_received(:delete).with("/images/sha256:old", force: false, noprune: true)
  end

  # @spec DOCKER-DISK-CLEANUP-002
  it "preserves young, malformed, agent, aliased protected, and container-referenced images" do
    images = [
      old_image.merge("Id" => "young", "Created" => Time.current.to_i),
      old_image.merge("Id" => "boundary", "Created" => cutoff),
      old_image.merge("Id" => "invalid", "Created" => nil),
      old_image.merge("Id" => "base", "RepoTags" => [ "paid-agent:latest" ]),
      old_image.merge("Id" => "combo", "RepoTags" => [ "paid-agent:go-node-python-ruby" ]),
      old_image.merge("Id" => "sha256:protected", "RepoTags" => [ "alias:latest" ]),
      old_image.merge("Id" => "running"),
      old_image.merge("Id" => "stopped")
    ]
    allow(connection).to receive(:get).with("/images/json").and_return(images.to_json)
    allow(connection).to receive(:get).with("/containers/json", all: true).and_return([
      { "ImageID" => "running", "State" => "running" },
      { "ImageID" => "stopped", "State" => "exited" }
    ].to_json)

    expect(service.call[:images_removed]).to eq(0)
    expect(connection).not_to have_received(:delete)
  end

  # @spec DOCKER-DISK-CLEANUP-003
  it "prunes only aged unused cache and never requests other resource deletion" do
    service.call

    expect(connection).to have_received(:post).once.with(
      "/build/prune", { all: true, filters: { until: [ "168h" ] }.to_json }, read_timeout: 15.minutes.to_i
    )
    expect(connection).to have_received(:delete).once.with("/images/sha256:old", force: false, noprune: true)
  end

  # @spec DOCKER-DISK-CLEANUP-001
  it "rejects a remote connection before discovery or deletion" do
    allow(connection).to receive(:options).and_return({})

    expect { service.call }.to raise_error(ArgumentError, /Unix socket/)
    expect(connection).not_to have_received(:get)
    expect(connection).not_to have_received(:post)
  end

  # @spec DOCKER-DISK-CLEANUP-004
  it "tolerates missing protected images" do
    allow(connection).to receive(:get).with("/images/custom:runtime/json").and_raise(Docker::Error::NotFoundError)

    expect(service.call[:images_removed]).to eq(1)
  end

  # @spec DOCKER-DISK-CLEANUP-004
  it "aborts before deletion when protection discovery fails" do
    allow(connection).to receive(:get).with("/images/custom:runtime/json").and_raise(Docker::Error::ServerError)

    expect { service.call }.to raise_error(Docker::Error::ServerError)
    expect(connection).not_to have_received(:delete)
    expect(connection).not_to have_received(:post)
  end

  # @spec DOCKER-DISK-CLEANUP-004
  it "surfaces container discovery errors before deletion" do
    allow(connection).to receive(:get).with("/containers/json", all: true).and_raise(Docker::Error::TimeoutError)

    expect { service.call }.to raise_error(Docker::Error::TimeoutError)
    expect(connection).not_to have_received(:delete)
    expect(connection).not_to have_received(:post)
  end

  [ Docker::Error::ConflictError, Docker::Error::NotFoundError ].each do |error|
    # @spec DOCKER-DISK-CLEANUP-002 DOCKER-DISK-CLEANUP-004
    it "retains an image on a deletion race (#{error})" do
      allow(connection).to receive(:delete).and_raise(error)

      expect(service.call[:images_removed]).to eq(0)
    end
  end

  # @spec DOCKER-DISK-CLEANUP-004
  it "surfaces cache pruning failures" do
    allow(connection).to receive(:post).and_raise(Docker::Error::TimeoutError)
    allow(Rails.logger).to receive(:info)

    expect { service.call }.to raise_error(Docker::Error::TimeoutError)
    expect(Rails.logger).to have_received(:info).with(hash_including(
      message: "container_manager.disk_cleanup_images_complete", images_removed: 1, image_bytes_estimate: 123
    ))
  end

  # @spec DOCKER-DISK-CLEANUP-004
  it "surfaces unexpected deletion failures without continuing" do
    allow(connection).to receive(:delete).and_raise(Docker::Error::ServerError)

    expect { service.call }.to raise_error(Docker::Error::ServerError)
    expect(connection).not_to have_received(:post)
  end
end
