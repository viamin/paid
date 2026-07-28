# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoolReplenishmentJob do
  it "has a 15-minute perform_timeout so a hung provisioning call cannot deadlock the Rails reloader" do
    expect(described_class.perform_timeout).to eq(15.minutes.to_i)
  end

  describe "#perform" do
    it "replenishes active projects across all configured backends under a per-project advisory lock" do
      active_project = create(:project)
      create(:project, :inactive)
      manager = instance_double(Containers::PoolManager, replenish_unlocked: nil)
      local_backend = instance_double(Containers::Backends::Base, identifier: "local")
      remote_backend = instance_double(Containers::Backends::Base, identifier: "elguapo")

      allow(Containers::PoolManager).to receive(:new).and_return(manager)
      allow(Containers).to receive(:all_backends).and_return([ local_backend, remote_backend ])
      allow(Containers::PoolManager).to receive(:with_project_replenishment_lock).and_yield

      described_class.perform_now

      expect(Containers::PoolManager).to have_received(:with_project_replenishment_lock).with(active_project)
      expect(Containers::PoolManager).to have_received(:new).with(project: active_project, container_host: "local")
      expect(Containers::PoolManager).to have_received(:new).with(project: active_project, container_host: "elguapo")
      expect(manager).to have_received(:replenish_unlocked).twice
    end
  end
end
