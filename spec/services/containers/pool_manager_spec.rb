# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::PoolManager do
  let(:project) { create(:project) }

  describe ".target_size" do
    it "uses a bounded global environment setting" do
      expect(described_class.target_size("PAID_CONTAINER_POOL_SIZE" => "2")).to eq(2)
      expect(described_class.target_size("PAID_CONTAINER_POOL_SIZE" => "200")).to eq(20)
    end

    it "falls back to zero for invalid values" do
      expect(described_class.target_size("PAID_CONTAINER_POOL_SIZE" => "invalid")).to eq(0)
    end
  end

  describe ".metrics" do
    let(:backends) do
      [
        instance_double(Containers::Backends::Base, identifier: "local"),
        instance_double(Containers::Backends::Base, identifier: "worker-1")
      ]
    end

    before do
      allow(Containers).to receive(:all_backends).and_return(backends)
    end

    it "returns counts for each status and zero-defaults missing statuses" do
      other_project = create(:project)
      create(:container_pool_entry, project: project)
      create(:container_pool_entry, project: project)
      create(:container_pool_entry, :warming, project: project)
      create(:container_pool_entry, :claimed, project: project)
      create(:container_pool_entry, :errored, project: project)
      # Entry for another project should not be counted
      create(:container_pool_entry, project: other_project)

      result = described_class.metrics(projects: Project.where(id: project.id))

      expect(result).to eq(
        warm: 2,
        warming: 1,
        claimed: 1,
        error: 1,
        target: described_class.target_size * backends.count
      )
    end

    it "uses two queries to load grouped counts and active project total" do
      create(:container_pool_entry, project: project)
      create(:container_pool_entry, :warming, project: project)

      query_count = count_queries do
        result = described_class.metrics(projects: Project.where(id: project.id))

        expect(result).to eq(
          warm: 1,
          warming: 1,
          claimed: 0,
          error: 0,
          target: described_class.target_size * backends.count
        )
      end

      expect(query_count).to eq(2)
    end

    it "returns zeros when no entries exist" do
      result = described_class.metrics(projects: Project.where(id: project.id))

      expect(result).to eq(
        warm: 0,
        warming: 0,
        claimed: 0,
        error: 0,
        target: described_class.target_size * backends.count
      )
    end
  end

  describe ".cleanup_claimed_container" do
    let(:agent_run) { create(:agent_run, project: project) }
    let(:container) { instance_double(Docker::Container, info: { "State" => { "Running" => true } }) }
    let(:volume) { instance_double(Docker::Volume) }
    let(:remote_backend) do
      instance_double(
        Containers::Backends::Base,
        get_container: container,
        stop_container: true,
        delete_container: true,
        get_volume: volume,
        delete_volume: true
      )
    end

    it "uses the persisted container host for workspace volume cleanup" do
      entry = create(
        :container_pool_entry,
        :claimed,
        project: project,
        agent_run: agent_run,
        container_host: "worker-1"
      )
      agent_run.update!(container_id: entry.container_id)
      allow(Containers).to receive(:backend_for).with("worker-1").and_return(remote_backend)

      expect(described_class.cleanup_claimed_container(agent_run: agent_run, force: true)).to be(true)
      expect(remote_backend).to have_received(:get_container).with(entry.container_id)
      expect(remote_backend).to have_received(:stop_container).with(container, timeout: 0)
      expect(remote_backend).to have_received(:delete_container).with(container, force: true, v: true)
      expect(remote_backend).to have_received(:get_volume).with(entry.workspace_volume, host: "worker-1")
      expect(remote_backend).to have_received(:delete_volume).with(volume)
      expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
    end

    it "does not tear down a newly claimed entry when the run has moved on to a different container" do
      entry = create(
        :container_pool_entry,
        :claimed,
        project: project,
        agent_run: agent_run,
        container_host: "worker-1"
      )
      agent_run.update!(container_id: "stale-container-id")

      expect(described_class.cleanup_claimed_container(agent_run: agent_run, force: true)).to be(false)
      expect(ContainerPoolEntry.exists?(entry.id)).to be(true)
    end
  end

  describe ".with_project_replenishment_lock" do
    it "acquires the per-project advisory lock for the duration of the block" do
      raw_connection = instance_double(PG::Connection, exec_params: true)
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:raw_connection).and_return(raw_connection)
      lock_key = project.id % 2_147_483_647

      yielded = false
      described_class.with_project_replenishment_lock(project) { yielded = true }

      expect(yielded).to be(true)
      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_lock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).once
      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_unlock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).once
    end

    it "releases the lock even when the block raises" do
      raw_connection = instance_double(PG::Connection, exec_params: true)
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:raw_connection).and_return(raw_connection)
      lock_key = project.id % 2_147_483_647

      expect {
        described_class.with_project_replenishment_lock(project) { raise "boom" }
      }.to raise_error("boom")

      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_lock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).once
      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_unlock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).once
    end
  end

  describe "#acquire" do
    let(:agent_run) { create(:agent_run, project: project) }
    let(:service) { instance_double(Containers::Provision) }
    let(:container) { instance_double(Docker::Container, info: { "State" => { "Running" => true } }, stop: true, delete: true) }
    let(:volume) { instance_double(Docker::Volume, remove: true) }

    before do
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")
      run_network_probe = instance_double(Containers::Provision, network_name: "paid_agent")
      allow(Containers::Provision).to receive(:new).and_call_original
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)
      allow(Containers::Provision).to receive(:new).with(agent_run: agent_run).and_return(run_network_probe)
      allow(Docker::Container).to receive(:get).and_return(container)
      allow(Docker::Volume).to receive(:get).and_return(volume)
      allow(Containers::Provision).to receive(:reconnect).and_return(service)
      allow(PoolReplenishmentJob).to receive(:perform_later)
    end

    it "claims a warm container for an agent run" do
      entry = create(:container_pool_entry, project: project)

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_success
      expect(result[:container_id]).to eq(entry.container_id)
      expect(result[:container_host]).to eq(entry.container_host)
      expect(entry.reload.status).to eq("claimed")
      expect(entry.agent_run).to eq(agent_run)
      expect(Containers::Provision).to have_received(:reconnect).with(
        agent_run: agent_run,
        container_id: entry.container_id,
        workspace_volume: entry.workspace_volume,
        pool_entry: entry
      )
      expect(PoolReplenishmentJob).to have_received(:perform_later).with(project.id)
    end

    it "claims only warm entries on the requested host" do
      local_entry = create(:container_pool_entry, project: project, container_host: "local")
      remote_entry = create(:container_pool_entry, project: project, container_host: "elguapo")
      remote_backend = instance_double(
        Containers::Backends::Base,
        get_container: container,
        identifier: "elguapo",
        remote?: true
      )
      allow(Containers).to receive(:backend_for).and_return(remote_backend)

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run, container_host: "elguapo")

      expect(result).to be_success
      expect(result[:container_id]).to eq(remote_entry.container_id)
      expect(remote_entry.reload.status).to eq("claimed")
      expect(local_entry.reload.status).to eq("warm")
    end

    it "carries reconnect-safe options into the claimed warm container" do
      entry = create(:container_pool_entry, project: project)

      described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run, timeout_seconds: 120)

      expect(Containers::Provision).to have_received(:reconnect).with(
        agent_run: agent_run,
        container_id: entry.container_id,
        workspace_volume: entry.workspace_volume,
        pool_entry: entry,
        timeout_seconds: 120
      )
    end

    it "bypasses the pool for an unsupported runtime so provisioning fails loudly instead" do
      # @spec POLYGLOT-TEST-008
      entry = create(:container_pool_entry, project: project)
      project.update!(repo_profile: { "test_languages" => %w[Kotlin Ruby] })

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_nil
      expect(entry.reload.status).to eq("warm")
    end

    it "bypasses the pool when caller options require a different container shape" do
      entry = create(:container_pool_entry, project: project)

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run, memory_bytes: 8.gigabytes)

      expect(result).to be_nil
      expect(entry.reload.status).to eq("warm")
      expect(Containers::Provision).not_to have_received(:reconnect)
    end

    it "returns nil when the warm pool is disabled" do
      create(:container_pool_entry, project: project)

      result = described_class.new(project: project, target_size: 0).acquire(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "returns nil when the run requires a different network contract" do
      run_network_probe = instance_double(Containers::Provision, network_name: "paid_internal")
      allow(Containers::Provision).to receive(:new).with(agent_run: agent_run).and_return(run_network_probe)
      agent_run.update!(agent_type: "kilocode")
      create(:container_pool_entry, project: project)

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_nil
      expect(Containers::Provision).not_to have_received(:reconnect)
    end

    it "returns nil when the run has service containers" do
      agent_run.update!(service_container_ids: [ 123 ])
      create(:container_pool_entry, project: project)

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_nil
      expect(Containers::Provision).not_to have_received(:reconnect)
    end

    it "removes a stale warm entry" do
      entry = create(:container_pool_entry, project: project)
      allow(container).to receive(:info).and_return({ "State" => { "Running" => false } })

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_nil
      expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
    end

    it "removes reconnect failures so cold provisioning can continue" do
      entry = create(:container_pool_entry, project: project)
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "Container #{entry.container_id} not found")

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_nil
      expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
    end

    it "records the warm-time runtime image selection on the claiming run" do
      # @spec IMMUTABLE-IMAGE-002
      warm_metadata = runtime_image_selection_metadata(digest: "a" * 64)
      create(:container_pool_entry, project: project, runtime_image_metadata: warm_metadata)

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_success
      expect(agent_run.reload.runtime_image_selection).to eq(warm_metadata)
    end

    it "does not touch run provenance when the claimed entry has no persisted selection" do
      create(:container_pool_entry, project: project)

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_success
      expect(agent_run.reload.runtime_image_selection).to be_nil
    end
  end

  describe "#replenish" do
    it "serializes replenishment per project with an advisory lock" do
      create(:container_pool_entry, :warming, project: project)
      connection = ActiveRecord::Base.connection
      raw_connection = instance_double(PG::Connection, exec_params: true)
      lock_key = project.id % 2_147_483_647
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")
      allow(connection).to receive(:raw_connection).and_return(raw_connection)
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)

      described_class.new(project: project, target_size: 0).replenish
      described_class.new(project: project, target_size: 1).replenish

      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_lock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).twice
      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_unlock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).twice
    end

    it "provisions missing warm entries up to the target size" do
      provision = instance_double(Containers::Provision)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-1", container_host: "local"),
        runtime_image_selection: nil
      )

      described_class.new(project: project, target_size: 1).replenish

      entry = project.container_pool_entries.sole
      expect(entry.status).to eq("warm")
      expect(entry.container_id).to eq("warm-1")
      expect(entry.container_host).to eq("local")
    end

    it "persists the warm-time runtime image selection on the warmed entry" do
      # @spec IMMUTABLE-IMAGE-002
      selection = runtime_image_selection_result(digest: "a" * 64)
      provision = instance_double(Containers::Provision)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-1", container_host: "local"),
        runtime_image_selection: selection
      )

      described_class.new(project: project, target_size: 1).replenish

      expect(project.container_pool_entries.sole.runtime_image_selection).to eq(selection.metadata)
    end

    it "warms entries with the project-resolved image for extended runtimes" do
      project.update!(primary_language: "Go")
      provision = instance_double(Containers::Provision)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-go", container_host: "local"),
        runtime_image_selection: nil
      )

      described_class.new(project: project, target_size: 1).replenish

      entry = project.container_pool_entries.sole
      expect(entry.image).to eq("paid-agent:go")
    end

    it "warms nothing for an unsupported runtime instead of falling back to the base image" do
      # @spec POLYGLOT-TEST-008
      project.update!(repo_profile: { "test_languages" => %w[Kotlin Ruby] })
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)

      described_class.new(project: project, target_size: 1).replenish

      expect(project.container_pool_entries).to be_empty
    end

    it "drains warm entries left over from a supported earlier profile" do
      # @spec POLYGLOT-TEST-008
      entry = create(:container_pool_entry, project: project)
      project.update!(repo_profile: { "test_languages" => %w[Kotlin Ruby] })
      container = instance_double(Docker::Container, info: { "State" => { "Running" => true } }, stop: true, delete: true)
      volume = instance_double(Docker::Volume, remove: true)
      allow(Docker::Container).to receive(:get).with(entry.container_id).and_return(container)
      allow(Docker::Volume).to receive(:get).with(entry.workspace_volume).and_return(volume)

      described_class.new(project: project, target_size: 1).replenish

      expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
    end

    it "keeps replenishing other projects when one has an unsupported runtime" do
      unsupported = create(:project, repo_profile: { "test_languages" => %w[Kotlin] })
      provision = instance_double(Containers::Provision)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-1", container_host: "local"),
        runtime_image_selection: nil
      )

      expect {
        [ unsupported, project ].each { |proj| described_class.new(project: proj, target_size: 1).replenish }
      }.not_to raise_error

      expect(unsupported.container_pool_entries).to be_empty
      expect(project.container_pool_entries.warm.sole.container_id).to eq("warm-1")
    end

    it "keeps host-specific target counts separate during replenishment" do
      create(:container_pool_entry, project: project, container_host: "local")
      provision = instance_double(Containers::Provision)

      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-remote", container_host: "elguapo"),
        runtime_image_selection: nil
      )

      described_class.new(project: project, target_size: 1, container_host: "elguapo").replenish

      expect(project.container_pool_entries.where(container_host: "local").count).to eq(1)
      expect(project.container_pool_entries.where(container_host: "elguapo").warm.pluck(:container_id)).to eq([ "warm-remote" ])
    end

    it "removes stopped warm entries before counting pool capacity" do
      stale_entry = create(:container_pool_entry, project: project)
      stopped_container = instance_double(Docker::Container, info: { "State" => { "Running" => false } }, delete: true)
      volume = instance_double(Docker::Volume, remove: true)
      provision = instance_double(Containers::Provision)

      allow(Docker::Container).to receive(:get).with(stale_entry.container_id).and_return(stopped_container)
      allow(Docker::Volume).to receive(:get).with(stale_entry.workspace_volume).and_return(volume)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-2", container_host: "local"),
        runtime_image_selection: nil
      )

      described_class.new(project: project, target_size: 1).replenish

      expect(ContainerPoolEntry.exists?(stale_entry.id)).to be(false)
      expect(project.container_pool_entries.warm.sole.container_id).to eq("warm-2")
    end

    it "removes stale warming entries before counting pool capacity" do
      stale_entry = create(:container_pool_entry, :warming, project: project, created_at: 1.hour.ago)
      volume = instance_double(Docker::Volume, remove: true)
      provision = instance_double(Containers::Provision)

      allow(Docker::Volume).to receive(:get).with(stale_entry.workspace_volume).and_return(volume)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-3", container_host: "local"),
        runtime_image_selection: nil
      )

      described_class.new(project: project, target_size: 1).replenish

      expect(ContainerPoolEntry.exists?(stale_entry.id)).to be(false)
      expect(project.container_pool_entries.warm.sole.container_id).to eq("warm-3")
    end

    it "keeps claimed entries for retained agent runs" do
      agent_run = create(:agent_run, :failed, project: project, container_retained_until: 2.hours.from_now)
      entry = create(:container_pool_entry, :claimed, project: project, agent_run: agent_run)
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")

      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)

      described_class.new(project: project, target_size: 0).replenish

      expect(ContainerPoolEntry.exists?(entry.id)).to be(true)
    end

    it "cleans up claimed entries only for the replenished host" do
      remote_entry, local_entry, remote_backend, remote_container, remote_volume =
        prepare_claimed_entry_cleanup_for_host(project: project)
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")

      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)
      allow(Containers).to receive(:backend_for).with("elguapo").and_return(remote_backend)

      described_class.new(project: project, target_size: 0, container_host: "elguapo").replenish

      expect(ContainerPoolEntry.exists?(remote_entry.id)).to be(false)
      expect(ContainerPoolEntry.exists?(local_entry.id)).to be(true)
      expect(remote_backend).to have_received(:get_container).with(remote_entry.container_id)
      expect(remote_backend).to have_received(:stop_container).with(remote_container, timeout: 0)
      expect(remote_backend).to have_received(:delete_container).with(remote_container, force: true, v: true)
      expect(remote_backend).to have_received(:get_volume).with(remote_entry.workspace_volume, host: "elguapo")
      expect(remote_backend).to have_received(:delete_volume).with(remote_volume)
    end

    it "removes warm entries with an old network" do
      stale_entry = create(:container_pool_entry, project: project, network: "paid_internal")

      expect_replenish_to_remove_stale_warm_entry(stale_entry)
    end

    it "removes warm entries with an old image" do
      stale_entry = create(:container_pool_entry, project: project, image: "old-image")

      expect_replenish_to_remove_stale_warm_entry(stale_entry)
    end

    it "removes warm entries when the target size is zero" do
      entry = create(:container_pool_entry, project: project)
      container = instance_double(Docker::Container, info: { "State" => { "Running" => true } }, stop: true, delete: true)
      volume = instance_double(Docker::Volume, remove: true)
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")
      backend = Containers.backend

      allow(Docker::Container).to receive(:get).with(entry.container_id).and_return(container)
      allow(Docker::Volume).to receive(:get).with(entry.workspace_volume).and_return(volume)
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)
      allow(backend).to receive(:stop_container).and_call_original
      allow(backend).to receive(:delete_container).and_call_original

      described_class.new(project: project, target_size: 0).replenish

      expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
      expect(backend).to have_received(:stop_container).with(container, timeout: 0)
      expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
      expect(container).to have_received(:delete).with(force: true, v: true)
      expect(volume).to have_received(:remove)
    end

    it "trims excess warm entries when the target size is reduced" do
      older_entry = create(:container_pool_entry, project: project, warmed_at: 2.hours.ago)
      newer_entry = create(:container_pool_entry, project: project, warmed_at: 1.hour.ago)
      older_container = instance_double(Docker::Container, info: { "State" => { "Running" => true } }, stop: true, delete: true)
      newer_container = instance_double(Docker::Container, info: { "State" => { "Running" => true } })
      volume = instance_double(Docker::Volume, remove: true)
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")
      backend = Containers.backend

      allow(Docker::Container).to receive(:get).with(older_entry.container_id).and_return(older_container)
      allow(Docker::Container).to receive(:get).with(newer_entry.container_id).and_return(newer_container)
      allow(Docker::Volume).to receive(:get).with(older_entry.workspace_volume).and_return(volume)
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)
      allow(backend).to receive(:stop_container).and_call_original
      allow(backend).to receive(:delete_container).and_call_original

      described_class.new(project: project, target_size: 1).replenish

      expect(ContainerPoolEntry.exists?(older_entry.id)).to be(false)
      expect(ContainerPoolEntry.exists?(newer_entry.id)).to be(true)
      expect(backend).to have_received(:stop_container).with(older_container, timeout: 0)
      expect(backend).to have_received(:delete_container).with(older_container, force: true, v: true)
      expect(older_container).to have_received(:delete).with(force: true, v: true)
    end

    it "removes entries when provisioning fails" do
      provision = instance_double(Containers::Provision)
      volume = instance_double(Docker::Volume, remove: true)

      allow(Docker::Volume).to receive(:get).and_return(volume)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(network_name: "paid_agent", cleanup: nil)
      allow(provision).to receive(:provision).and_raise(Containers::Provision::ProvisionError, "image unavailable")

      described_class.new(project: project, target_size: 1).replenish

      expect(project.container_pool_entries.reload.count).to eq(0)
      expect(provision).to have_received(:cleanup).with(force: true)
    end

    it "re-raises perform timeouts instead of swallowing them as provisioning failures" do
      provision = instance_double(Containers::Provision)

      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive(:network_name).and_return("paid_agent")
      allow(provision).to receive(:provision).and_raise(ApplicationJob::PerformTimeoutError, "perform timeout")

      expect {
        described_class.new(project: project, target_size: 1).replenish
      }.to raise_error(ApplicationJob::PerformTimeoutError, "perform timeout")

      expect(project.container_pool_entries.reload.pluck(:status)).to eq([ "warming" ])
    end
  end

  describe "#replenish_unlocked" do
    it "provisions missing warm entries up to the target size without acquiring the advisory lock" do
      provision = instance_double(Containers::Provision)
      allow(Containers::Provision).to receive(:new).and_return(provision)
      allow(provision).to receive_messages(
        network_name: "paid_agent",
        provision: Containers::Provision::Result.success(container_id: "warm-1", container_host: "local"),
        runtime_image_selection: nil
      )
      connection = ActiveRecord::Base.connection
      raw_connection = instance_double(PG::Connection, exec_params: true)
      allow(connection).to receive(:raw_connection).and_return(raw_connection)

      described_class.new(project: project, target_size: 1).replenish_unlocked

      entry = project.container_pool_entries.sole
      expect(entry.status).to eq("warm")
      expect(entry.container_id).to eq("warm-1")
      expect(entry.container_host).to eq("local")
      expect(raw_connection).not_to have_received(:exec_params)
    end
  end

  def runtime_image_selection_metadata(digest:, provenance_reference: "base-amd64-2026-08-19")
    {
      "requested_image" => "paid-agent:latest",
      "resolved_image" => "ghcr.io/viamin/paid-agent@sha256:#{digest}",
      "digest" => "sha256:#{digest}",
      "architecture" => "amd64",
      "registry" => "ghcr.io",
      "repository" => "viamin/paid-agent",
      "provenance_reference" => provenance_reference,
      "immutable" => true
    }
  end

  def runtime_image_selection_result(digest:)
    Containers::RuntimeImageSelector::Result.from_metadata(
      runtime_image_selection_metadata(digest: digest)
    )
  end

  def expect_replenish_to_remove_stale_warm_entry(stale_entry)
    container = instance_double(Docker::Container, info: { "State" => { "Running" => true } }, stop: true, delete: true)
    volume = instance_double(Docker::Volume, remove: true)
    provision = instance_double(Containers::Provision)
    backend = Containers.backend
    allow(Docker::Container).to receive(:get).with(stale_entry.container_id).and_return(container)
    allow(Docker::Volume).to receive(:get).with(stale_entry.workspace_volume).and_return(volume)
    allow(Containers::Provision).to receive(:new).and_return(provision)
    allow(provision).to receive_messages(
      network_name: "paid_agent",
      provision: Containers::Provision::Result.success(container_id: "warm-4", container_host: "local"),
      runtime_image_selection: nil
    )
    allow(backend).to receive(:stop_container).and_call_original
    allow(backend).to receive(:delete_container).and_call_original

    described_class.new(project: project, target_size: 1).replenish

    expect(ContainerPoolEntry.exists?(stale_entry.id)).to be(false)
    expect(project.container_pool_entries.warm.sole.container_id).to eq("warm-4")
    expect(backend).to have_received(:stop_container).with(container, timeout: 0)
    expect(backend).to have_received(:delete_container).with(container, force: true, v: true)
    expect(container).to have_received(:delete).with(force: true, v: true)
    expect(volume).to have_received(:remove)
  end

  def prepare_claimed_entry_cleanup_for_host(project:)
    finished_run = create(:agent_run, :completed, project: project)
    remote_entry = create(
      :container_pool_entry,
      :claimed,
      project: project,
      agent_run: finished_run,
      container_host: "elguapo"
    )
    local_entry = create(
      :container_pool_entry,
      :claimed,
      project: project,
      agent_run: finished_run,
      container_host: "local"
    )
    remote_container = instance_double(Docker::Container, info: { "State" => { "Running" => true } })
    remote_volume = instance_double(Docker::Volume)
    remote_backend = instance_double(
      Containers::Backends::Base,
      get_container: remote_container,
      stop_container: true,
      delete_container: true,
      get_volume: remote_volume,
      delete_volume: true
    )
    [ remote_entry, local_entry, remote_backend, remote_container, remote_volume ]
  end
end
