# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProviderApiKey do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:providers).dependent(:restrict_with_error) }
  end

  describe "validations" do
    subject(:api_key) { build(:provider_api_key) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:user_id) }
    it { is_expected.to validate_presence_of(:api_key) }
    it { is_expected.to validate_presence_of(:compatible_providers) }

    it "rejects unsupported provider keys in compatible_providers" do
      api_key.compatible_providers = %w[claude unknown_provider]

      expect(api_key).not_to be_valid
      expect(api_key.errors[:compatible_providers].first).to include("unsupported")
    end

    it "accepts valid provider keys in compatible_providers" do
      api_key.compatible_providers = %w[claude cursor]

      expect(api_key).to be_valid
    end
  end

  describe "#compatible_with?" do
    let(:api_key) { build(:provider_api_key, compatible_providers: %w[claude gemini]) }

    it "returns true for compatible providers" do
      expect(api_key.compatible_with?("claude")).to be(true)
      expect(api_key.compatible_with?("gemini")).to be(true)
    end

    it "returns false for incompatible providers" do
      expect(api_key.compatible_with?("cursor")).to be(false)
    end
  end

  describe "destroy restriction" do
    it "prevents deletion when providers are associated" do
      api_key = create(:provider_api_key)
      create(:provider, user: api_key.user, provider_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(api_key.destroy).to be(false)
      expect(api_key.errors[:base]).to be_present
    end

    it "allows deletion when no providers are associated" do
      api_key = create(:provider_api_key)

      expect(api_key.destroy).to be_truthy
    end
  end

  describe ".compatible_with" do
    let(:user) { create(:user) }

    it "returns keys compatible with a given provider" do
      claude_key = create(:provider_api_key, user: user, compatible_providers: %w[claude])
      create(:provider_api_key, user: user, name: "Other key", compatible_providers: %w[cursor])

      result = described_class.compatible_with("claude")
      expect(result).to include(claude_key)
      expect(result.size).to eq(1)
    end
  end
end
