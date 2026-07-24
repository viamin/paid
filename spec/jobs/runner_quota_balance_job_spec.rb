# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerQuotaBalanceJob do
  describe "#perform" do
    it "rebalances users with auto-weighting enabled" do
      enabled = create(:user_setting, auto_weight_enabled: true)
      create(:user_setting, auto_weight_enabled: false)
      allow(Runners::QuotaBalanceService).to receive(:call)

      described_class.perform_now

      expect(Runners::QuotaBalanceService).to have_received(:call).with(user: enabled.user)
      expect(Runners::QuotaBalanceService).to have_received(:call).once
    end

    it "can rebalance a single user" do
      enabled = create(:user_setting, auto_weight_enabled: true)
      other = create(:user_setting, auto_weight_enabled: true)
      allow(Runners::QuotaBalanceService).to receive(:call)

      described_class.perform_now(enabled.user.id)

      expect(Runners::QuotaBalanceService).to have_received(:call).with(user: enabled.user)
      expect(Runners::QuotaBalanceService).not_to have_received(:call).with(user: other.user)
    end

    it "uses the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end
  end
end
