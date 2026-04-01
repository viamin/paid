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
    it { is_expected.to validate_presence_of(:api_service_type) }

    it "rejects unsupported api_service_type values" do
      api_key.api_service_type = "unknown_service"

      expect(api_key).not_to be_valid
      expect(api_key.errors[:api_service_type].first).to include("not a supported")
    end

    it "accepts valid api_service_type values" do
      api_key.api_service_type = "anthropic"

      expect(api_key).to be_valid
    end
  end

  describe "#compatible_with?" do
    let(:api_key) { build(:provider_api_key, api_service_type: "anthropic") }

    it "returns true for providers whose API service type matches" do
      expect(api_key.compatible_with?("claude")).to be(true)
    end

    it "returns false for providers whose API service type differs" do
      expect(api_key.compatible_with?("codex")).to be(false)
    end

    it "returns false for providers with no API service type mapping" do
      expect(api_key.compatible_with?("copilot")).to be(false)
      expect(api_key.compatible_with?("unknown")).to be(false)
    end
  end

  describe "#display_api_service_type" do
    it "returns the human-readable label for the service type" do
      api_key = build(:provider_api_key, api_service_type: "openrouter")

      expect(api_key.display_api_service_type).to eq("OpenRouter")
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

  describe ".for_api_service_type" do
    let(:user) { create(:user) }

    it "returns keys with the matching api_service_type" do
      anthropic_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      create(:provider_api_key, user: user, name: "Other key", api_service_type: "openai")

      result = described_class.for_api_service_type("anthropic")
      expect(result).to include(anthropic_key)
      expect(result.size).to eq(1)
    end
  end

  describe ".api_service_type_options" do
    it "returns label-value pairs for all service types" do
      options = described_class.api_service_type_options

      expect(options).to include(%w[Anthropic anthropic])
      expect(options).to include(%w[OpenRouter openrouter])
      expect(options).to include(%w[OpenAI openai])
      expect(options).to include([ "Google AI", "google" ])
    end
  end
end
