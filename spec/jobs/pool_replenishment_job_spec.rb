# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoolReplenishmentJob do
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
