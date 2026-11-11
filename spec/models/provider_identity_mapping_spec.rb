# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProviderIdentityMapping do
  describe ".user_for and .identity_for" do
    it "resolves the mapped Paid user for a provider identity and back" do
      # @spec UNIFIED-WORK-ITEMS-004
      account = create(:account)
      user = create(:user, account:)
      mapping = create(:provider_identity_mapping, account:, user:, external_id: "linear-user-9")

      expect(described_class.user_for(account:, provider: "linear", external_id: "linear-user-9")).to eq(user)
      expect(described_class.identity_for(account:, provider: "linear", user:)).to eq(mapping)
    end
  end

  describe "validations" do
    it "rejects a second mapping for the same user and provider" do
      account = create(:account)
      user = create(:user, account:)
      create(:provider_identity_mapping, account:, user:)

      duplicate = build(:provider_identity_mapping, account:, user:)

      expect(duplicate).not_to be_valid
    end

    it "rejects a second user mapped to the same external identity" do
      account = create(:account)
      create(:provider_identity_mapping, account:, user: create(:user, account:), external_id: "linear-user-5")

      duplicate = build(:provider_identity_mapping, account:, user: create(:user, account:), external_id: "linear-user-5")

      expect(duplicate).not_to be_valid
    end
  end
end
