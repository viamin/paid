# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::ProviderHealth do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account, name: "Operator One", email: "operator@example.com") }
    let(:default_provider) { user.providers.find_by!(provider_key: Provider.default_provider_key, auth_type: "subscription") }
    let(:secondary_provider_key) { (ProviderSupport.container_executable_provider_keys - [ default_provider.provider_key ]).first || "cursor" }

    it "returns configured provider health for the account" do
      available_provider = default_provider
      rate_limited_provider = create(:provider, user: user, provider_key: secondary_provider_key, auth_type: "subscription")
      create(:provider_state, user: user, provider_name: rate_limited_provider.state_key, rate_limited_until: 10.minutes.from_now)

      stats = described_class.call(account: account)

      expect(stats).to include(
        total: 2,
        available: 1,
        rate_limited: 1,
        circuit_open: 0,
        recovering: 0,
        healthy: false
      )
      expect(stats[:providers].map(&:provider)).to eq([ rate_limited_provider.display_name, available_provider.display_name ])
      expect(stats[:providers].map(&:status)).to eq([ :rate_limited, :available ])
    end

    it "filters providers to the current account" do
      default_provider

      other_user = create(:user)
      create(:provider, user: other_user, provider_key: secondary_provider_key)

      stats = described_class.call(account: account)

      expect(stats[:total]).to eq(1)
      expect(stats[:providers].map(&:owner_email)).to eq([ user.email ])
    end
  end
end
