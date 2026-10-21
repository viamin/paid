# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServiceContainerReconciliationJob do
  let(:job) { described_class.new }
  let(:backend) { instance_double(Containers::Backends::Base) }

  before do
    allow(Containers).to receive(:backend_for).and_return(backend)
  end

  describe "#perform" do
    it "corrects running DB records when Docker container is gone" do
      sc = create(:service_container, status: "running", docker_container_id: "dead123", container_host: "elguapo")
      allow(backend).to receive(:get_container).with("dead123")
        .and_raise(Docker::Error::NotFoundError)

      job.perform

      sc.reload
      expect(sc.status).to eq("stopped")
      expect(sc.docker_container_id).to be_nil
      expect(sc.container_host).to be_nil
    end

    it "leaves running containers that are actually running in Docker" do
      sc = create(:service_container, status: "running", docker_container_id: "alive123", container_host: "elguapo")
      container = instance_double(Docker::Container)
      allow(backend).to receive(:get_container).with("alive123").and_return(container)
      allow(container).to receive(:json).and_return({ "State" => { "Running" => true } })

      job.perform

      sc.reload
      expect(sc.status).to eq("running")
      expect(sc.docker_container_id).to eq("alive123")
    end

    # @spec TOOLCHAIN-PIN-026, CONTAINER-RUNTIME-042
    it "reports runtime image drift without replacing the running service" do
      sc = build(:service_container, image: "postgres:16.15", status: "running", docker_container_id: "old123")
      sc.save!(validate: false)
      container = instance_double(Docker::Container)
      allow(backend).to receive(:get_container).with("old123").and_return(container)
      allow(container).to receive(:json).and_return(
        { "State" => { "Running" => true }, "Config" => { "Image" => "postgres:16.13" } }
      )
      allow(Rails.logger).to receive(:warn)

      job.perform

      expect(sc.reload).to have_attributes(status: "running", docker_container_id: "old123")
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "container_manager.service_container_image_drift",
          requested_image: "postgres:16.15",
          runtime_image: "postgres:16.13",
          remediation: "drain consumers, then update the service container and recreate it"
        )
      )
    end

    # @spec TOOLCHAIN-PIN-026, CONTAINER-RUNTIME-042
    it "reports an older configured PostgreSQL default without replacing the running service" do
      sc = build(:service_container, image: "postgres:16.13", status: "running", docker_container_id: "old-default")
      sc.save!(validate: false)
      container = instance_double(Docker::Container)
      allow(backend).to receive(:get_container).with("old-default").and_return(container)
      allow(container).to receive(:json).and_return(
        { "State" => { "Running" => true }, "Config" => { "Image" => "postgres:16.13" } }
      )
      allow(Rails.logger).to receive(:warn)

      job.perform

      expect(sc.reload).to have_attributes(status: "running", docker_container_id: "old-default")
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "container_manager.service_container_default_image_drift",
          configured_image: "postgres:16.13",
          default_image: "postgres:16.15",
          runtime_image: "postgres:16.13"
        )
      )
    end

    # @spec TOOLCHAIN-PIN-026, CONTAINER-RUNTIME-042
    # Anchoring the match to the repository segment prevents every reconciliation
    # cycle from emitting a spurious default-drift warning for registry-mirrored
    # PostgreSQL images (e.g. the ECR pull-through used by pr-screenshots.yml).
    it "does not flag a registry-prefixed PostgreSQL image when it matches the current default" do
      sc = build(:service_container,
                 image: "registry.example.com/postgres:16.15",
                 status: "running", docker_container_id: "mirrored")
      sc.save!(validate: false)
      container = instance_double(Docker::Container)
      allow(backend).to receive(:get_container).with("mirrored").and_return(container)
      allow(container).to receive(:json).and_return(
        { "State" => { "Running" => true }, "Config" => { "Image" => "registry.example.com/postgres:16.15" } }
      )
      allow(Rails.logger).to receive(:warn)

      job.perform

      expect(sc.reload).to have_attributes(status: "running", docker_container_id: "mirrored")
      expect(Rails.logger).not_to have_received(:warn).with(
        hash_including(message: "container_manager.service_container_default_image_drift")
      )
    end

    # @spec TOOLCHAIN-PIN-026, CONTAINER-RUNTIME-042
    # A registry-prefixed image at an older version is still drift — the
    # comparison strips the registry mirror so the version, not the prefix,
    # determines whether to warn.
    it "still flags a registry-prefixed PostgreSQL image that lags the current default" do
      sc = build(:service_container,
                 image: "registry.example.com/postgres:16.13",
                 status: "running", docker_container_id: "mirrored-old")
      sc.save!(validate: false)
      container = instance_double(Docker::Container)
      allow(backend).to receive(:get_container).with("mirrored-old").and_return(container)
      allow(container).to receive(:json).and_return(
        { "State" => { "Running" => true }, "Config" => { "Image" => "registry.example.com/postgres:16.13" } }
      )
      allow(Rails.logger).to receive(:warn)

      job.perform

      expect(sc.reload).to have_attributes(status: "running", docker_container_id: "mirrored-old")
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "container_manager.service_container_default_image_drift",
          configured_image: "registry.example.com/postgres:16.13",
          default_image: "postgres:16.15",
          runtime_image: "registry.example.com/postgres:16.13"
        )
      )
    end

    it "corrects records when Docker container exists but is stopped" do
      sc = create(:service_container, status: "running", docker_container_id: "stopped123", container_host: "elguapo")
      container = instance_double(Docker::Container)
      allow(backend).to receive(:get_container).with("stopped123").and_return(container)
      allow(container).to receive(:json).and_return({ "State" => { "Running" => false } })

      job.perform

      sc.reload
      expect(sc.status).to eq("stopped")
      expect(sc.docker_container_id).to be_nil
      expect(sc.container_host).to be_nil
    end

    it "skips non-running service containers" do
      sc = create(:service_container, status: "stopped", docker_container_id: nil)
      allow(backend).to receive(:get_container)

      job.perform

      expect(backend).not_to have_received(:get_container)
      expect(sc.reload.status).to eq("stopped")
    end

    it "skips containers on transient Docker API errors" do
      sc1 = create(:service_container, status: "running", docker_container_id: "err123", container_host: "elguapo")
      sc2 = create(:service_container, status: "running", docker_container_id: "gone456", container_host: "elguapo")

      allow(backend).to receive(:get_container).with("err123")
        .and_raise(Docker::Error::DockerError, "daemon error")
      allow(backend).to receive(:get_container).with("gone456")
        .and_raise(Docker::Error::NotFoundError)

      job.perform

      # sc1 remains running because transient errors are not treated as drift
      expect(sc1.reload.status).to eq("running")
      # sc2 is corrected because NotFoundError confirms the container is gone
      expect(sc2.reload.status).to eq("stopped")
    end

    it "corrects records when docker_container_id is blank" do
      sc = create(:service_container, status: "running", docker_container_id: nil, container_host: "elguapo")

      job.perform

      sc.reload
      expect(sc.status).to eq("stopped")
      expect(sc.docker_container_id).to be_nil
      expect(sc.container_host).to be_nil
    end

    it "checks the persisted host instead of the active default backend" do
      sc = create(:service_container, status: "running", docker_container_id: "remote123", container_host: "elguapo")
      container = instance_double(Docker::Container, json: { "State" => { "Running" => true } })

      allow(Containers).to receive(:backend_for).with("elguapo").and_return(backend)
      allow(backend).to receive(:get_container).with("remote123").and_return(container)

      job.perform

      expect(Containers).to have_received(:backend_for).with("elguapo")
      expect(backend).to have_received(:get_container).with("remote123")
      expect(sc.reload.status).to eq("running")
    end
  end
end
