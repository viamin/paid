# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListProviderApiKeys do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  describe Tools::ListProviderApiKeys do
    it "lists the current user's API keys" do
      key = create(:provider_api_key, user:)

      result = described_class.new(user:, session:).call

      expect(result.map { |row| row[:id] }).to include(key.id)
    end
  end

  describe Tools::CreateProviderApiKey do
    it "creates a provider API key" do
      result = described_class.new(user:, session:).call(
        name: "OpenAI",
        api_key: "sk-test",
        api_service_type: "openai",
        confirmed: true
      )

      expect(result[:name]).to eq("OpenAI")
      expect(user.provider_api_keys.find(result[:id]).api_service_type).to eq("openai")
    end
  end

  describe Tools::UpdateProviderApiKey do
    it "updates a provider API key" do
      provider_api_key = create(:provider_api_key, user:, api_service_type: "openai")

      result = described_class.new(user:, session:).call(
        provider_api_key_id: provider_api_key.id,
        attributes: { name: "Renamed" },
        confirmed: true
      )

      expect(result[:name]).to eq("Renamed")
      expect(provider_api_key.reload.name).to eq("Renamed")
    end
  end

  describe Tools::RemoveProviderApiKey do
    it "removes a provider API key" do
      provider_api_key = create(:provider_api_key, user:)

      result = described_class.new(user:, session:).call(
        provider_api_key_id: provider_api_key.id,
        confirmed: true
      )

      expect(result[:id]).to eq(provider_api_key.id)
      expect(user.provider_api_keys.where(id: provider_api_key.id)).to be_empty
    end
  end
end
