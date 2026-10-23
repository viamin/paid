# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerDiskCleanupJob do
  let(:connection) { instance_double(Docker::Connection, options: { socket: "/var/run/docker.sock" }) }

  before do
    allow(Docker).to receive(:connection).and_return(connection)
    allow(connection).to receive(:get).with("/images/json").and_return("[]")
    allow(connection).to receive(:get).with("/containers/json", all: true).and_return("[]")
    allow(connection).to receive(:get).with(%r{\A/images/.+/json\z}).and_return({ "Id" => "protected" }.to_json)
    allow(connection).to receive(:post).and_return({ "SpaceReclaimed" => 789 }.to_json)
    allow(Rails.logger).to receive(:info)
  end

  around do |example|
    original = ENV["PAID_DOCKER_DISK_CLEANUP_ENABLED"]
    original_digests = ENV["PAID_AGENT_RUNTIME_DIGESTS"]
    ENV.delete("PAID_AGENT_RUNTIME_DIGESTS")
    ENV.delete("PAID_DOCKER_DISK_CLEANUP_ENABLED")
    example.run
  ensure
    ENV["PAID_DOCKER_DISK_CLEANUP_ENABLED"] = original
    ENV["PAID_AGENT_RUNTIME_DIGESTS"] = original_digests
  end

  # @spec DOCKER-DISK-CLEANUP-001
  it "does nothing unless explicitly enabled" do
    expect(Docker).not_to receive(:connection)
    described_class.new.perform
  end

  # @spec DOCKER-DISK-CLEANUP-001
  it "has a daily maintenance schedule and concurrency limits" do
    schedule = Rails.application.config.good_job.cron.fetch(:docker_disk_cleanup)
    expect(schedule).to include(cron: "17 4 * * * UTC", class: "DockerDiskCleanupJob", queue: "maintenance")
    expect(described_class.perform_timeout).to eq(20.minutes.to_i)
    expect(described_class.good_job_concurrency_config).to include(
      total_limit: 1, enqueue_limit: 1, key: "docker_disk_cleanup"
    )
  end

  # @spec DOCKER-DISK-CLEANUP-002 DOCKER-DISK-CLEANUP-004
  it "protects configured catalog images and logs cleanup results" do
    ENV["PAID_DOCKER_DISK_CLEANUP_ENABLED"] = "true"
    ENV["PAID_AGENT_RUNTIME_DIGESTS"] = {
      "custom:unused" => { "digest" => "sha256:#{'a' * 64}", "architecture" => "arm64" }
    }.to_json
    image = create(:agent_image)
    create(:project, repo_profile: { "languages" => [ "Go" ] })

    described_class.new.perform

    expect(connection).to have_received(:get).with("/images/#{image.reference}/json")
    expect(connection).to have_received(:get).with("/images/#{image.digest_reference}/json")
    expect(connection).to have_received(:get).with("/images/paid-agent:latest/json")
    expect(connection).to have_received(:get).with("/images/paid-agent:go/json")
    expect(connection).to have_received(:get).with("/images/ghcr.io/viamin/paid-agent@sha256:#{'a' * 64}/json")
    expect(Rails.logger).to have_received(:info).with(hash_including(
      message: "container_manager.disk_cleanup_complete", images_removed: 0,
      cache_bytes_reclaimed: 789, image_bytes_estimate: 0, duration_ms: a_kind_of(Integer)
    ))
  end

  # @spec DOCKER-DISK-CLEANUP-004
  it "aborts before contacting Docker if an unselected runtime profile is malformed" do
    ENV["PAID_DOCKER_DISK_CLEANUP_ENABLED"] = "true"
    ENV["PAID_AGENT_RUNTIME_DIGESTS"] = "{invalid-json"
    expect(Docker).not_to receive(:connection)

    expect { described_class.new.perform }.to raise_error(Containers::RuntimeImageCatalog::Error)
  end

  # @spec DOCKER-DISK-CLEANUP-004
  it "logs and re-raises daemon failures" do
    ENV["PAID_DOCKER_DISK_CLEANUP_ENABLED"] = "true"
    allow(Docker).to receive(:connection).and_raise(Docker::Error::TimeoutError)
    allow(Rails.logger).to receive(:error)

    expect { described_class.new.perform }.to raise_error(Docker::Error::TimeoutError)
    expect(Rails.logger).to have_received(:error).with(hash_including(message: "container_manager.disk_cleanup_failed"))
  end
end
