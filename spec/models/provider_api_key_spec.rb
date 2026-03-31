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

    it "rejects unsupported API services in compatible_providers" do
      api_key.compatible_providers = %w[openai unknown_service]

      expect(api_key).not_to be_valid
      expect(api_key.errors[:compatible_providers].first).to include("unsupported API services")
    end

    it "accepts valid API services in compatible_providers" do
      api_key.compatible_providers = %w[openai openrouter]

      expect(api_key).to be_valid
    end
  end

  describe "#compatible_with?" do
    let(:api_key) { build(:provider_api_key, compatible_providers: %w[openai google]) }

    it "returns true for compatible API services" do
      expect(api_key.compatible_with?("openai")).to be(true)
      expect(api_key.compatible_with?("google")).to be(true)
    end

    it "returns false for incompatible API services" do
      expect(api_key.compatible_with?("openrouter")).to be(false)
    end
  end

  describe ".compatibility_target_labels" do
    it "returns API service labels" do
      labels = described_class.compatibility_target_labels

      expect(labels).to include("openai" => "OpenAI")
      expect(labels).to include("openrouter" => "OpenRouter")
      expect(labels).to include("google" => "Google")
      expect(labels).to include("github" => "GitHub")
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

    it "returns keys compatible with a given API service" do
      openai_key = create(:provider_api_key, user: user, compatible_providers: %w[openai])
      create(:provider_api_key, user: user, name: "Other key", compatible_providers: %w[openrouter])

      result = described_class.compatible_with("openai")
      expect(result).to include(openai_key)
      expect(result.size).to eq(1)
    end
  end
end
