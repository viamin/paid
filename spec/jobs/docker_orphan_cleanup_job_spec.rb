# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerOrphanCleanupJob do
  let(:job) { described_class.new }
  let(:agent_filter) { { label: [ "paid.agent_run_id" ] }.to_json }
  let(:service_filter) { { label: [ "paid.service_container=true" ] }.to_json }

  def stub_no_containers
    allow(Docker::Container).to receive(:all).and_return([])
  end

  def stub_no_volumes
    allow(Docker::Volume).to receive(:all).and_return([])
  end

  def stub_agent_containers(*containers)
    allow(Docker::Container).to receive(:all)
      .with(all: true, filters: agent_filter)
      .and_return(containers)
  end

  def stub_service_containers(*containers)
    allow(Docker::Container).to receive(:all)
      .with(all: true, filters: service_filter)
      .and_return(containers)
  end

  def make_container(labels:)
    instance_double(Docker::Container,
      info: { "Labels" => labels },
      stop: true,
      delete: true)
  end

  describe "#perform" do
    context "with agent containers" do
      before do
        stub_no_volumes
        stub_service_containers
      end

      it "removes containers for finished agent runs" do
        completed_run = create(:agent_run, :completed)
        container = make_container(labels: { "paid.agent_run_id" => completed_run.id.to_s })
        stub_agent_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
      end

      it "attempts to stop containers before removing them" do
        completed_run = create(:agent_run, :completed)
        container = make_container(labels: { "paid.agent_run_id" => completed_run.id.to_s })
        stub_agent_containers(container)

        job.perform

        expect(container).to have_received(:stop).with(timeout: 10)
        expect(container).to have_received(:delete).with(force: true, v: true)
      end

      it "still removes containers when stop raises ClientError" do
        completed_run = create(:agent_run, :completed)
        container = make_container(labels: { "paid.agent_run_id" => completed_run.id.to_s })
        allow(container).to receive(:stop).and_raise(Docker::Error::ClientError, "container already stopped")
        stub_agent_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
      end

      it "treats NotFoundError on delete as successful removal" do
        completed_run = create(:agent_run, :completed)
        container = make_container(labels: { "paid.agent_run_id" => completed_run.id.to_s })
        allow(container).to receive(:delete).and_raise(Docker::Error::NotFoundError, "no such container")
        stub_agent_containers(container)

        expect { job.perform }.not_to raise_error
      end

      it "skips containers for active agent runs" do
        running_run = create(:agent_run, status: "running")
        container = make_container(labels: { "paid.agent_run_id" => running_run.id.to_s })
        stub_agent_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      it "removes containers with no matching agent run in DB" do
        container = make_container(labels: { "paid.agent_run_id" => "999999" })
        stub_agent_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
      end

      it "continues processing when individual container removal fails" do
        completed1 = create(:agent_run, :completed)
        completed2 = create(:agent_run, :completed)
        container1 = make_container(labels: { "paid.agent_run_id" => completed1.id.to_s })
        container2 = make_container(labels: { "paid.agent_run_id" => completed2.id.to_s })
        allow(container1).to receive(:delete).and_raise(Docker::Error::DockerError, "conflict")
        stub_agent_containers(container1, container2)

        job.perform

        expect(container2).to have_received(:delete).with(force: true, v: true)
      end

      it "handles Docker errors when listing containers" do
        allow(Docker::Container).to receive(:all)
          .with(all: true, filters: agent_filter)
          .and_raise(Docker::Error::DockerError, "daemon error")
        stub_no_volumes

        expect { job.perform }.not_to raise_error
      end
    end

    context "with service containers" do
      before do
        stub_no_volumes
        stub_agent_containers
      end

      it "removes service containers with zero active agent runs" do
        sc = create(:service_container, status: "running")
        container = make_container(labels: {
          "paid.service_container" => "true",
          "paid.service_container_id" => sc.id.to_s
        })
        stub_service_containers(container)
        allow(sc).to receive(:active_agent_run_count).and_return(0)
        allow(ServiceContainer).to receive(:find_by).with(id: sc.id.to_s).and_return(sc)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
        expect(sc.reload.status).to eq("stopped")
      end

      it "skips service containers with active agent runs" do
        sc = create(:service_container, status: "running")
        container = make_container(labels: {
          "paid.service_container" => "true",
          "paid.service_container_id" => sc.id.to_s
        })
        stub_service_containers(container)
        allow(sc).to receive(:active_agent_run_count).and_return(1)
        allow(ServiceContainer).to receive(:find_by).with(id: sc.id.to_s).and_return(sc)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      it "removes service containers with no matching DB record" do
        container = make_container(labels: {
          "paid.service_container" => "true",
          "paid.service_container_id" => "999999"
        })
        stub_service_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
      end
    end

    context "with volumes" do
      before { stub_no_containers }

      it "removes volumes for completed agent runs" do
        completed_run = create(:agent_run, :completed)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{completed_run.id}", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips volumes for active agent runs" do
        running_run = create(:agent_run, status: "running")
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{running_run.id}", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "removes volumes with no matching agent run" do
        volume = instance_double(Docker::Volume, id: "paid-workspace-nonexistent-id", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips volumes not matching the paid-workspace prefix" do
        volume = instance_double(Docker::Volume, id: "other-volume-123", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "treats NotFoundError during volume removal as a successful removal" do
        completed_run = create(:agent_run, :completed)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{completed_run.id}")
        allow(volume).to receive(:remove).and_raise(Docker::Error::NotFoundError)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "continues processing when individual volume removal fails" do
        completed1 = create(:agent_run, :completed)
        completed2 = create(:agent_run, :completed)
        volume1 = instance_double(Docker::Volume, id: "paid-workspace-#{completed1.id}")
        volume2 = instance_double(Docker::Volume, id: "paid-workspace-#{completed2.id}", remove: true)
        allow(volume1).to receive(:remove).and_raise(Docker::Error::DockerError, "volume in use")
        allow(Docker::Volume).to receive(:all).and_return([ volume1, volume2 ])

        job.perform

        expect(volume2).to have_received(:remove)
      end

      it "handles Docker errors when listing volumes" do
        allow(Docker::Volume).to receive(:all).and_raise(Docker::Error::DockerError, "daemon error")

        expect { job.perform }.not_to raise_error
      end
    end
  end
end
