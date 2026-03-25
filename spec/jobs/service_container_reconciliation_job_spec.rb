# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServiceContainerReconciliationJob do
  let(:job) { described_class.new }

  describe "#perform" do
    it "corrects running DB records when Docker container is gone" do
      sc = create(:service_container, status: "running", docker_container_id: "dead123")
      allow(Docker::Container).to receive(:get).with("dead123")
        .and_raise(Docker::Error::NotFoundError)

      job.perform

      sc.reload
      expect(sc.status).to eq("stopped")
      expect(sc.docker_container_id).to be_nil
    end

    it "leaves running containers that are actually running in Docker" do
      sc = create(:service_container, status: "running", docker_container_id: "alive123")
      container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get).with("alive123").and_return(container)
      allow(container).to receive(:json).and_return({ "State" => { "Running" => true } })

      job.perform

      sc.reload
      expect(sc.status).to eq("running")
      expect(sc.docker_container_id).to eq("alive123")
    end

    it "corrects records when Docker container exists but is stopped" do
      sc = create(:service_container, status: "running", docker_container_id: "stopped123")
      container = instance_double(Docker::Container)
      allow(Docker::Container).to receive(:get).with("stopped123").and_return(container)
      allow(container).to receive(:json).and_return({ "State" => { "Running" => false } })

      job.perform

      sc.reload
      expect(sc.status).to eq("stopped")
      expect(sc.docker_container_id).to be_nil
    end

    it "skips non-running service containers" do
      sc = create(:service_container, status: "stopped", docker_container_id: nil)
      allow(Docker::Container).to receive(:get)

      job.perform

      expect(Docker::Container).not_to have_received(:get)
      expect(sc.reload.status).to eq("stopped")
    end

    it "skips containers on transient Docker API errors" do
      sc1 = create(:service_container, status: "running", docker_container_id: "err123")
      sc2 = create(:service_container, status: "running", docker_container_id: "gone456")

      allow(Docker::Container).to receive(:get).with("err123")
        .and_raise(Docker::Error::DockerError, "daemon error")
      allow(Docker::Container).to receive(:get).with("gone456")
        .and_raise(Docker::Error::NotFoundError)

      job.perform

      # sc1 remains running because transient errors are not treated as drift
      expect(sc1.reload.status).to eq("running")
      # sc2 is corrected because NotFoundError confirms the container is gone
      expect(sc2.reload.status).to eq("stopped")
    end

    it "corrects records when docker_container_id is blank" do
      sc = create(:service_container, status: "running", docker_container_id: nil)

      job.perform

      sc.reload
      expect(sc.status).to eq("stopped")
      expect(sc.docker_container_id).to be_nil
    end
  end
end
