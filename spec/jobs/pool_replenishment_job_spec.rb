# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoolReplenishmentJob do
  it "has a 15-minute perform_timeout so a hung provisioning call cannot deadlock the Rails reloader" do
    expect(described_class.perform_timeout).to eq(15.minutes.to_i)
  end

  describe "#perform" do
    it "replenishes active projects" do
      active_project = create(:project)
      create(:project, :inactive)
      manager = instance_double(Containers::PoolManager, replenish: nil)

      allow(Containers::PoolManager).to receive(:new).and_return(manager)

      described_class.perform_now

      expect(Containers::PoolManager).to have_received(:new).with(project: active_project)
      expect(manager).to have_received(:replenish).once
    end
  end
end
