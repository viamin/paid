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

  describe "#acquire" do
    let(:agent_run) { create(:agent_run, project: project) }
    let(:service) { instance_double(Containers::Provision) }
    let(:container) { instance_double(Docker::Container, info: { "State" => { "Running" => true } }) }

    before do
      network_probe = instance_double(Containers::Provision, network_name: "paid_agent")
      allow(Containers::Provision).to receive(:new).and_call_original
      allow(Containers::Provision).to receive(:new).with(project: project).and_return(network_probe)
      allow(Docker::Container).to receive(:get).and_return(container)
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

    it "returns nil when the warm pool is disabled" do
      create(:container_pool_entry, project: project)

      result = described_class.new(project: project, target_size: 0).acquire(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "marks a stale warm entry as errored" do
      entry = create(:container_pool_entry, project: project)
      allow(container).to receive(:info).and_return({ "State" => { "Running" => false } })

      result = described_class.new(project: project, target_size: 1).acquire(agent_run: agent_run)

      expect(result).to be_nil
      expect(entry.reload.status).to eq("error")
      expect(entry.last_error).to include("not running")
    end
  end

  describe "#replenish" do
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
  end
end
