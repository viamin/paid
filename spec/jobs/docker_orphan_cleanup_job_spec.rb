# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerOrphanCleanupJob do
  let(:job) { described_class.new }
  let(:agent_filter) { { label: [ "paid.agent_run_id" ] }.to_json }
  let(:pool_filter) { { label: [ "paid.container_pool=true" ] }.to_json }
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

  def stub_pool_containers(*containers)
    allow(Docker::Container).to receive(:all)
      .with(all: true, filters: pool_filter)
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
        stub_pool_containers
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

      it "skips containers for claimed queued runs" do
        claimed_run = create(:agent_run, status: "queued", temporal_workflow_id: "workflow-123")
        container = make_container(labels: { "paid.agent_run_id" => claimed_run.id.to_s })
        stub_agent_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      it "skips containers for retained agent runs" do
        retained_run = create(:agent_run, :failed, container_retained_until: 2.hours.from_now)
        container = make_container(labels: { "paid.agent_run_id" => retained_run.id.to_s })
        stub_agent_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      it "removes containers for agent runs with expired retention" do
        expired_run = create(:agent_run, :failed, container_retained_until: 1.hour.ago)
        container = make_container(labels: { "paid.agent_run_id" => expired_run.id.to_s })
        stub_agent_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
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
        stub_pool_containers
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

      it "skips service containers with claimed queued runs" do
        sc = create(:service_container, status: "running")
        project = create(:project)
        create(:project_service_container, project: project, service_container: sc)
        issue = create(:issue, project: project)
        create(:agent_run, status: "queued", temporal_workflow_id: "workflow-123", project: project, issue: issue,
          service_container_ids: [ sc.id ])
        container = make_container(labels: {
          "paid.service_container" => "true",
          "paid.service_container_id" => sc.id.to_s
        })
        stub_service_containers(container)

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

    context "with pool containers" do
      before do
        stub_no_volumes
        stub_agent_containers
        stub_service_containers
      end

      it "skips fresh warming pool containers" do
        entry = create(:container_pool_entry, :warming)
        container = make_container(labels: {
          "paid.container_pool" => "true",
          "paid.container_pool_entry_id" => entry.id.to_s
        })
        stub_pool_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      it "removes stale warming pool containers" do
        entry = create(:container_pool_entry, :warming, created_at: 1.hour.ago)
        container = make_container(labels: {
          "paid.container_pool" => "true",
          "paid.container_pool_entry_id" => entry.id.to_s
        })
        stub_pool_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
        expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
      end

      it "skips claimed pool containers for retained agent runs" do
        retained_run = create(:agent_run, :failed, container_retained_until: 2.hours.from_now)
        entry = create(:container_pool_entry, :claimed, agent_run: retained_run)
        container = make_container(labels: {
          "paid.container_pool" => "true",
          "paid.container_pool_entry_id" => entry.id.to_s
        })
        stub_pool_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      it "skips claimed pool containers for claimed queued runs" do
        claimed_run = create(:agent_run, status: "queued", temporal_workflow_id: "workflow-123")
        entry = create(:container_pool_entry, :claimed, agent_run: claimed_run)
        container = make_container(labels: {
          "paid.container_pool" => "true",
          "paid.container_pool_entry_id" => entry.id.to_s
        })
        stub_pool_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
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

      it "skips volumes for claimed queued runs" do
        claimed_run = create(:agent_run, status: "queued", temporal_workflow_id: "workflow-123")
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{claimed_run.id}", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "skips volumes for active agent runs" do
        running_run = create(:agent_run, status: "running")
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{running_run.id}", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "skips claimed pool volumes for active agent runs" do
        running_run = create(:agent_run, status: "running")
        entry = create(:container_pool_entry, :claimed, agent_run: running_run)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "removes claimed pool volumes for finished agent runs" do
        completed_run = create(:agent_run, :completed)
        entry = create(:container_pool_entry, :claimed, agent_run: completed_run)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips claimed pool volumes for retained agent runs" do
        retained_run = create(:agent_run, :failed, container_retained_until: 2.hours.from_now)
        entry = create(:container_pool_entry, :claimed, agent_run: retained_run)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "removes stale warming pool volumes" do
        entry = create(:container_pool_entry, :warming, created_at: 1.hour.ago)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "removes volumes with no matching agent run" do
        volume = instance_double(Docker::Volume, id: "paid-workspace-nonexistent-id", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips volumes for retained agent runs" do
        retained_run = create(:agent_run, :failed, container_retained_until: 2.hours.from_now)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{retained_run.id}", remove: true)
        allow(Docker::Volume).to receive(:all).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "removes volumes for agent runs with expired retention" do
        expired_run = create(:agent_run, :failed, container_retained_until: 1.hour.ago)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{expired_run.id}", remove: true)
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
