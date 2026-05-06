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
        target: described_class.target_size * 1
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
          target: described_class.target_size * 1
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
        target: described_class.target_size * 1
      )
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
        provision: Containers::Provision::Result.success(container_id: "warm-1")
      )

      described_class.new(project: project, target_size: 1).replenish

      entry = project.container_pool_entries.sole
      expect(entry.status).to eq("warm")
      expect(entry.container_id).to eq("warm-1")
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
        provision: Containers::Provision::Result.success(container_id: "warm-2")
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
        provision: Containers::Provision::Result.success(container_id: "warm-3")
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

      allow(Docker::Container).to receive(:get).with(entry.container_id).and_return(container)
      allow(Docker::Volume).to receive(:get).with(entry.workspace_volume).and_return(volume)
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)

      described_class.new(project: project, target_size: 0).replenish

      expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
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

      allow(Docker::Container).to receive(:get).with(older_entry.container_id).and_return(older_container)
      allow(Docker::Container).to receive(:get).with(newer_entry.container_id).and_return(newer_container)
      allow(Docker::Volume).to receive(:get).with(older_entry.workspace_volume).and_return(volume)
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)

      described_class.new(project: project, target_size: 1).replenish

      expect(ContainerPoolEntry.exists?(older_entry.id)).to be(false)
      expect(ContainerPoolEntry.exists?(newer_entry.id)).to be(true)
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
  end

  def expect_replenish_to_remove_stale_warm_entry(stale_entry)
    container = instance_double(Docker::Container, info: { "State" => { "Running" => true } }, stop: true, delete: true)
    volume = instance_double(Docker::Volume, remove: true)
    provision = instance_double(Containers::Provision)
    allow(Docker::Container).to receive(:get).with(stale_entry.container_id).and_return(container)
    allow(Docker::Volume).to receive(:get).with(stale_entry.workspace_volume).and_return(volume)
    allow(Containers::Provision).to receive(:new).and_return(provision)
    allow(provision).to receive_messages(
      network_name: "paid_agent",
      provision: Containers::Provision::Result.success(container_id: "warm-4")
    )

    described_class.new(project: project, target_size: 1).replenish

    expect(ContainerPoolEntry.exists?(stale_entry.id)).to be(false)
    expect(project.container_pool_entries.warm.sole.container_id).to eq("warm-4")
    expect(container).to have_received(:delete).with(force: true, v: true)
    expect(volume).to have_received(:remove)
  end
end
