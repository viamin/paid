# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntryVersion do
  describe "#destroy" do
    it "prevents deleting versions that have been attached to agent runs" do
      entry = create(:marketplace_entry)
      version = create(:marketplace_entry_version, marketplace_entry: entry)
      entry.update!(current_version: version)
      agent_run = create(:agent_run, project: create(:project, account: entry.account))
      create(:agent_run_marketplace_entry,
        agent_run: agent_run,
        marketplace_entry: entry,
        marketplace_entry_version: version)

      expect(version.destroy).to be(false)
      expect(version.errors[:base]).to include("cannot delete marketplace entry versions that have been attached to agent runs")
      expect(described_class.exists?(version.id)).to be(true)
    end
  end
end
