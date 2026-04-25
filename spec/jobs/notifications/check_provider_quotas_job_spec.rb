# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::CheckProviderQuotasJob do
  describe "#perform" do
    it "evaluates the quota rule with all providers in a single batch" do
      create(:provider)
      allow(Notifications::Rules::ProviderQuotaExhausted).to receive(:call)

      described_class.perform_now

      expect(Notifications::Rules::ProviderQuotaExhausted).to have_received(:call) do |scope:|
        expect(scope).to be_an(Array)
        expect(scope).to all(be_a(Provider))
      end
    end

    it "eager-loads provider_states to avoid N+1" do
      create(:provider)
      allow(Notifications::Rules::ProviderQuotaExhausted).to receive(:call)

      described_class.perform_now

      expect(Notifications::Rules::ProviderQuotaExhausted).to have_received(:call) do |scope:|
        scope.each do |provider|
          expect(provider.user.association(:provider_states)).to be_loaded
        end
      end
    end

    it "uses the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end
  end
end
