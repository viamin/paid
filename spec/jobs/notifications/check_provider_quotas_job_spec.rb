# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::CheckProviderQuotasJob do
  describe "#perform" do
    it "evaluates the quota rule for each provider" do
      provider = create(:provider)
      allow(Notifications::Rules::ProviderQuotaExhausted).to receive(:call)

      described_class.perform_now

      expect(Notifications::Rules::ProviderQuotaExhausted).to have_received(:call).with(scope: provider)
    end

    it "uses the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end
  end
end
