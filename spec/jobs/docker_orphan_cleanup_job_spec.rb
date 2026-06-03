# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerOrphanCleanupJob do
  let(:job) { described_class.new }
  let(:agent_filter) { { label: [ "paid.agent_run_id" ] }.to_json }
  let(:pool_filter) { { label: [ "paid.container_pool=true" ] }.to_json }
  let(:collector_filter) { { label: [ "paid.resource=collector_container" ] }.to_json }
  let(:service_filter) { { label: [ "paid.service_container=true" ] }.to_json }
  let(:backend) { Containers.backend }

  def build_backend(identifier:, remote:)
    instance_double(
      Containers::Backends::Base,
      identifier: identifier,
      remote?: remote,
      all_host_identifiers: [ identifier ],
      list_containers: [],
      list_volumes: [],
      stop_container: nil,
      delete_container: nil,
      delete_volume: nil
    )
  end

  def stub_no_containers
    allow(backend).to receive(:list_containers).and_return([])
  end

  def stub_no_volumes
    allow(backend).to receive(:list_volumes).and_return([])
  end

  def stub_agent_containers(*containers)
    allow(backend).to receive(:list_containers)
      .with(all: true, filters: agent_filter)
      .and_return(containers)
  end

  def stub_pool_containers(*containers)
    allow(backend).to receive(:list_containers)
      .with(all: true, filters: pool_filter)
      .and_return(containers)
  end

  def stub_service_containers(*containers)
    allow(backend).to receive(:list_containers)
      .with(all: true, filters: service_filter)
      .and_return(containers)
  end

  def stub_collector_containers(*containers)
    allow(backend).to receive(:list_containers)
      .with(all: true, filters: collector_filter)
      .and_return(containers)
  end

  # `state_shape: :hash` mirrors the swarm backend (nested { "Running" => bool });
  # `:string` mirrors Docker's list API used by the local/remote backends
  # ("running"/"exited"). Both occur in production and must be handled.
  def make_container(labels:, id: SecureRandom.hex(32), running: false, created_at: Time.current, mounts: [], state_shape: :hash)
    state = state_shape == :string ? (running ? "running" : "exited") : { "Running" => running }
    instance_double(Docker::Container,
      id: id,
      info: {
        "Labels" => labels,
        "State" => state,
        "Created" => created_at.iso8601,
        "Mounts" => mounts
      },
      stop: true,
      delete: true)
  end

  def stub_backend_resources(target_backend, agent: [], pool: [], collector: [], service: [], volumes: [])
    allow(target_backend).to receive(:list_containers).with(all: true, filters: agent_filter).and_return(agent)
    allow(target_backend).to receive(:list_containers).with(all: true, filters: pool_filter).and_return(pool)
    allow(target_backend).to receive(:list_containers).with(all: true, filters: collector_filter).and_return(collector)
    allow(target_backend).to receive(:list_containers).with(all: true, filters: service_filter).and_return(service)
    allow(target_backend).to receive(:list_volumes).and_return(volumes)
  end

  describe "#perform" do
    it "cleans up resources across all registered backends" do
      local_backend = build_backend(identifier: "local", remote: false)
      remote_backend = build_backend(identifier: "worker-1", remote: true)
      local_container = make_container(labels: { "paid.agent_run_id" => "999999" })
      remote_container = make_container(labels: { "paid.agent_run_id" => "888888" })

      allow(Containers).to receive(:all_backends).and_return([ local_backend, remote_backend ])
      stub_backend_resources(local_backend, agent: [ local_container ])
      allow(local_backend).to receive(:stop_container).with(local_container, timeout: 10)
      allow(local_backend).to receive(:delete_container).with(local_container, force: true, v: true)

      stub_backend_resources(remote_backend, agent: [ remote_container ])
      allow(remote_backend).to receive(:stop_container).with(remote_container, timeout: 10)
      allow(remote_backend).to receive(:delete_container).with(remote_container, force: true, v: true)

      job.perform

      expect(local_backend).to have_received(:delete_container).with(local_container, force: true, v: true)
      expect(remote_backend).to have_received(:delete_container).with(remote_container, force: true, v: true)
    end

    context "with agent containers" do
      before do
        stub_no_volumes
        stub_service_containers
        stub_pool_containers
        stub_collector_containers
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

      it "removes wrong-host orphaned containers even when the run is still active on another backend" do
        remote_run = create(:agent_run, :running, container_host: "worker-1")
        local_backend = build_backend(identifier: "local", remote: false)
        remote_backend = build_backend(identifier: "worker-1", remote: true)
        local_container = make_container(labels: { "paid.agent_run_id" => remote_run.id.to_s })
        remote_container = make_container(labels: { "paid.agent_run_id" => remote_run.id.to_s })

        allow(Containers).to receive(:all_backends).and_return([ local_backend, remote_backend ])
        stub_backend_resources(local_backend, agent: [ local_container ])
        allow(local_backend).to receive(:stop_container).with(local_container, timeout: 10)
        allow(local_backend).to receive(:delete_container).with(local_container, force: true, v: true)

        stub_backend_resources(remote_backend, agent: [ remote_container ])

        job.perform

        expect(local_backend).to have_received(:delete_container).with(local_container, force: true, v: true)
        expect(remote_backend).not_to have_received(:delete_container)
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
        allow(backend).to receive(:list_containers)
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
        stub_collector_containers
      end

      it "removes service containers with zero in-flight capacity runs" do
        sc = create(:service_container, status: "running")
        container = make_container(labels: {
          "paid.service_container" => "true",
          "paid.service_container_id" => sc.id.to_s
        })
        stub_service_containers(container)
        allow(sc).to receive(:capacity_inflight_agent_run_count).and_return(0)
        allow(ServiceContainer).to receive(:find_by).with(id: sc.id.to_s).and_return(sc)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
        expect(sc.reload.status).to eq("stopped")
      end

      it "skips service containers with running agent runs" do
        sc = create(:service_container, status: "running")
        container = make_container(labels: {
          "paid.service_container" => "true",
          "paid.service_container_id" => sc.id.to_s
        })
        stub_service_containers(container)
        allow(sc).to receive(:capacity_inflight_agent_run_count).and_return(1)
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

      it "removes stale service containers whose docker_container_id no longer matches" do
        sc = create(:service_container, status: "running", docker_container_id: "active-container-on-remote")
        stale_container = make_container(
          id: "old-local-container-id",
          labels: {
            "paid.service_container" => "true",
            "paid.service_container_id" => sc.id.to_s
          }
        )
        stub_service_containers(stale_container)
        allow(sc).to receive(:capacity_inflight_agent_run_count).and_return(2)
        allow(ServiceContainer).to receive(:find_by).with(id: sc.id.to_s).and_return(sc)

        job.perform

        expect(stale_container).to have_received(:delete).with(force: true, v: true)
        expect(sc.reload.docker_container_id).to eq("active-container-on-remote")
        expect(sc.reload.status).to eq("running")
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
        stub_collector_containers
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

      it "removes wrong-host orphaned pool containers even when the entry is active on another backend" do
        remote_entry = create(:container_pool_entry, container_host: "worker-1")
        local_backend = build_backend(identifier: "local", remote: false)
        remote_backend = build_backend(identifier: "worker-1", remote: true)
        local_container = make_container(labels: {
          "paid.container_pool" => "true",
          "paid.container_pool_entry_id" => remote_entry.id.to_s
        })
        remote_container = make_container(labels: {
          "paid.container_pool" => "true",
          "paid.container_pool_entry_id" => remote_entry.id.to_s
        })

        allow(Containers).to receive(:all_backends).and_return([ local_backend, remote_backend ])
        stub_backend_resources(local_backend, pool: [ local_container ])
        allow(local_backend).to receive(:stop_container).with(local_container, timeout: 10)
        allow(local_backend).to receive(:delete_container).with(local_container, force: true, v: true)

        stub_backend_resources(remote_backend, pool: [ remote_container ])

        job.perform

        expect(local_backend).to have_received(:delete_container).with(local_container, force: true, v: true)
        expect(remote_backend).not_to have_received(:delete_container)
      end
    end

    context "with collector containers" do
      before do
        stub_no_volumes
        stub_agent_containers
        stub_pool_containers
        stub_service_containers
      end

      it "removes stopped collector containers" do
        container = make_container(
          labels: { "paid.resource" => "collector_container", "paid.project_id" => "42" },
          running: false
        )
        stub_collector_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
      end

      it "keeps running collector containers regardless of age" do
        container = make_container(
          labels: { "paid.resource" => "collector_container", "paid.project_id" => "42" },
          running: true,
          created_at: 2.hours.ago
        )
        stub_collector_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      # Regression: the list API (local/remote backends) returns State as a string,
      # not the nested hash the swarm backend builds. A running collector reported
      # this way must still be treated as active so its volume is not deleted.
      it "keeps running collector containers reported with list-API string state" do
        container = make_container(
          labels: { "paid.resource" => "collector_container", "paid.project_id" => "42" },
          running: true,
          state_shape: :string
        )
        stub_collector_containers(container)

        job.perform

        expect(container).not_to have_received(:delete)
      end

      it "removes stopped collector containers reported with list-API string state" do
        container = make_container(
          labels: { "paid.resource" => "collector_container", "paid.project_id" => "42" },
          running: false,
          state_shape: :string
        )
        stub_collector_containers(container)

        job.perform

        expect(container).to have_received(:delete).with(force: true, v: true)
      end
    end

    context "with volumes" do
      before do
        stub_no_containers
        stub_collector_containers
      end

      it "returns a complete empty summary when no paid volumes exist" do
        stub_no_volumes

        expect(job.send(:cleanup_volumes, backend: backend)).to eq(
          found: 0,
          removed: 0,
          failed: 0,
          active: 0,
          retained: 0
        )
      end

      it "removes volumes for completed agent runs" do
        completed_run = create(:agent_run, :completed)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{completed_run.id}", remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips volumes for claimed queued runs" do
        claimed_run = create(:agent_run, status: "queued", temporal_workflow_id: "workflow-123")
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{claimed_run.id}", remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "skips volumes for active agent runs" do
        running_run = create(:agent_run, status: "running")
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{running_run.id}", remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "skips claimed pool volumes for active agent runs" do
        running_run = create(:agent_run, status: "running")
        entry = create(:container_pool_entry, :claimed, agent_run: running_run)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "removes claimed pool volumes for finished agent runs" do
        completed_run = create(:agent_run, :completed)
        entry = create(:container_pool_entry, :claimed, agent_run: completed_run)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips claimed pool volumes for retained agent runs" do
        retained_run = create(:agent_run, :failed, container_retained_until: 2.hours.from_now)
        entry = create(:container_pool_entry, :claimed, agent_run: retained_run)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "removes stale warming pool volumes" do
        entry = create(:container_pool_entry, :warming, created_at: 1.hour.ago)
        volume = instance_double(Docker::Volume, id: entry.workspace_volume, remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "removes volumes with no matching agent run" do
        volume = instance_double(Docker::Volume, id: "paid-workspace-nonexistent-id", remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "removes stale collector volumes not mounted by active collector containers" do
        volume = instance_double(
          Docker::Volume,
          id: "paid-collector-42-deadbeef",
          info: { "Labels" => { "paid.created_at" => 2.hours.ago.iso8601 } },
          remove: true
        )
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips fresh collector volumes that are not mounted yet" do
        volume = instance_double(
          Docker::Volume,
          id: "paid-collector-42-deadbeef",
          info: { "Labels" => { "paid.created_at" => 5.minutes.ago.iso8601 } },
          remove: true
        )
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "skips collector volumes mounted by active collector containers" do
        active_collector = make_container(
          labels: { "paid.resource" => "collector_container", "paid.project_id" => "42" },
          running: true,
          created_at: 5.minutes.ago,
          mounts: [ { "Type" => "volume", "Name" => "paid-collector-42-deadbeef" } ]
        )
        volume = instance_double(
          Docker::Volume,
          id: "paid-collector-42-deadbeef",
          info: { "Labels" => { "paid.created_at" => 2.hours.ago.iso8601 } },
          remove: true
        )
        stub_collector_containers(active_collector)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "skips volumes for retained agent runs" do
        retained_run = create(:agent_run, :failed, container_retained_until: 2.hours.from_now)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{retained_run.id}", remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "removes volumes for agent runs with expired retention" do
        expired_run = create(:agent_run, :failed, container_retained_until: 1.hour.ago)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{expired_run.id}", remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "skips volumes not matching the paid-workspace prefix" do
        volume = instance_double(Docker::Volume, id: "other-volume-123", remove: true)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).not_to have_received(:remove)
      end

      it "treats NotFoundError during volume removal as a successful removal" do
        completed_run = create(:agent_run, :completed)
        volume = instance_double(Docker::Volume, id: "paid-workspace-#{completed_run.id}")
        allow(volume).to receive(:remove).and_raise(Docker::Error::NotFoundError)
        allow(backend).to receive(:list_volumes).and_return([ volume ])

        job.perform

        expect(volume).to have_received(:remove)
      end

      it "continues processing when individual volume removal fails" do
        completed1 = create(:agent_run, :completed)
        completed2 = create(:agent_run, :completed)
        volume1 = instance_double(Docker::Volume, id: "paid-workspace-#{completed1.id}")
        volume2 = instance_double(Docker::Volume, id: "paid-workspace-#{completed2.id}", remove: true)
        allow(volume1).to receive(:remove).and_raise(Docker::Error::DockerError, "volume in use")
        allow(backend).to receive(:list_volumes).and_return([ volume1, volume2 ])

        job.perform

        expect(volume2).to have_received(:remove)
      end

      it "handles Docker errors when listing volumes" do
        allow(backend).to receive(:list_volumes).and_raise(Docker::Error::DockerError, "daemon error")

        expect { job.perform }.not_to raise_error
      end

      it "removes wrong-host orphaned pool volumes even when the entry is active on another backend" do
        remote_entry = create(:container_pool_entry, container_host: "worker-1")
        local_backend = build_backend(identifier: "local", remote: false)
        remote_backend = build_backend(identifier: "worker-1", remote: true)
        local_volume = instance_double(Docker::Volume, id: remote_entry.workspace_volume, remove: true)
        remote_volume = instance_double(Docker::Volume, id: remote_entry.workspace_volume, remove: true)

        allow(Containers).to receive(:all_backends).and_return([ local_backend, remote_backend ])
        allow(local_backend).to receive_messages(list_containers: [], list_volumes: [ local_volume ])
        allow(local_backend).to receive(:delete_volume).with(local_volume)

        allow(remote_backend).to receive_messages(list_containers: [], list_volumes: [ remote_volume ])

        job.perform

        expect(local_backend).to have_received(:delete_volume).with(local_volume)
        expect(remote_backend).not_to have_received(:delete_volume)
      end
    end
  end
end
