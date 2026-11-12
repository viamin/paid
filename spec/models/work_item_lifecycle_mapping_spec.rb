# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItemLifecycleMapping do
  describe ".paid_state_for and .native_state_for" do
    it "resolves bidirectionally through the account default" do
      # @spec UNIFIED-WORK-ITEMS-006
      account = create(:account)
      create(:work_item_lifecycle_mapping, account:, native_state: "Todo", paid_state: "open")

      expect(described_class.paid_state_for(account:, provider: "linear", native_state: "Todo")).to eq("open")
      expect(described_class.native_state_for(account:, provider: "linear", paid_state: "open")).to eq("Todo")
    end

    it "prefers a project override over the account default" do
      account = create(:account)
      project = create(:project, account:)
      create(:work_item_lifecycle_mapping, account:, native_state: "Todo", paid_state: "open")
      create(:work_item_lifecycle_mapping, account:, project:, native_state: "Todo", paid_state: "backlog")

      expect(described_class.paid_state_for(account:, provider: "linear", native_state: "Todo", project:)).to eq("backlog")
    end

    it "returns nil when no mapping covers the state" do
      account = create(:account)

      expect(described_class.paid_state_for(account:, provider: "linear", native_state: "Unmapped")).to be_nil
    end
  end
end
