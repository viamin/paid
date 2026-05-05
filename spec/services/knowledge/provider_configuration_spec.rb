# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ProviderConfiguration do
  describe ".for_embedding" do
    let(:project) { create(:project) }
    let(:owner) { project.effective_owner }

    it "returns the configured provider key and base URL" do
      owner.settings.update!(
        kb_embedding_provider: "openrouter",
        kb_embedding_fallback_providers: [ "openai" ]
      )
      api_key = create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-openrouter")

      config = described_class.for_embedding(project: project)

      expect(config.provider).to eq("openrouter")
      expect(config.api_key).to eq(api_key.api_key)
      expect(config.api_base_url).to eq("https://openrouter.ai/api/v1")
      expect(config.api_key_record).to eq(api_key)
      expect(config.source).to eq(:user_key)
    end

    it "falls back to the next configured provider when the primary is unavailable" do
      owner.settings.update!(
        kb_embedding_provider: "openai",
        kb_embedding_fallback_providers: [ "openrouter" ]
      )
      create(:provider_state, user: owner, provider_name: "openai", rate_limited_until: 5.minutes.from_now)
      api_key = create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-openrouter")

      config = described_class.for_embedding(project: project)

      expect(config.provider).to eq("openrouter")
      expect(config.api_key).to eq(api_key.api_key)
    end

    it "uses the platform OpenAI key when OpenAI is selected and no user key exists" do
      owner.settings.update!(kb_embedding_provider: "openai", kb_embedding_fallback_providers: [])
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-platform")
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("OPENAI_API_BASE_URL", "https://api.openai.com").and_return("https://proxy.openai.test")

      config = described_class.for_embedding(project: project)

      expect(config.provider).to eq("openai")
      expect(config.api_key).to eq("sk-platform")
      expect(config.api_base_url).to eq("https://proxy.openai.test")
      expect(config.source).to eq(:platform_env)
    end

    it "uses the platform OpenAI key from Rails credentials when no user key exists" do
      owner.settings.update!(kb_embedding_provider: "openai", kb_embedding_fallback_providers: [])
      allow(Rails.application.credentials).to receive(:dig).with(:llm, :openai_api_key).and_return("sk-platform")

      config = described_class.for_embedding(project: project)

      expect(config.provider).to eq("openai")
      expect(config.api_key).to eq("sk-platform")
      expect(config.source).to eq(:platform_env)
    end

    it "ignores legacy embedding providers that are not OpenAI-compatible" do
      owner.settings.update_columns(
        kb_embedding_provider: "anthropic",
        kb_embedding_fallback_providers: [ "openai" ]
      )
      allow(Rails.logger).to receive(:warn)
      api_key = create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-openai")

      config = described_class.for_embedding(project: project)

      expect(config.provider).to eq("openai")
      expect(config.api_key).to eq(api_key.api_key)
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "knowledge.provider_selector.unsupported_provider_configured",
          user_setting_id: owner.settings.id,
          operation: :embedding,
          providers: [ "anthropic" ]
        )
      )
    end
  end

  describe ".for_embedding_candidate_providers" do
    let(:project) { create(:project) }
    let(:owner) { project.effective_owner }

    it "returns provider identifiers without loading API keys" do
      owner.settings.update!(
        kb_embedding_provider: "openrouter",
        kb_embedding_fallback_providers: [ "openai" ]
      )
      create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-openrouter")
      create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-openai")

      candidates = described_class.for_embedding_candidate_providers(project: project)

      expect(candidates.map(&:provider)).to eq(%w[openrouter openai])
      expect(candidates).to all(satisfy { |c| c.api_key.nil? })
    end

    it "filters out providers without configured credentials" do
      owner.settings.update!(
        kb_embedding_provider: "openrouter",
        kb_embedding_fallback_providers: [ "deepseek", "openai" ]
      )
      allow(Rails.application.credentials).to receive(:dig).with(:llm, :openai_api_key).and_return(nil)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)

      candidates = described_class.for_embedding_candidate_providers(project: project)

      expect(candidates).to be_empty
    end
  end
end
