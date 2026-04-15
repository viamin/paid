# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbedChunksJob do
  let(:project) { create(:project) }

  describe "#perform" do
    it "calls the embedding pipeline without a project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)

      described_class.perform_now

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(
        project: nil,
        api_key: nil,
        api_base_url: nil
      )
    end

    it "skips the embedding pipeline when no provider is configured for the project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      allow(project).to receive(:knowledge_embedding_provider_configuration).and_return(nil)
      allow(Project).to receive(:find).with(project.id).and_return(project)

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).not_to have_received(:call)
    end

    it "resolves the API key and base URL from the configured knowledge embedding provider" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      owner = project.effective_owner
      owner.settings.update!(kb_embedding_provider: "openrouter", kb_embedding_fallback_providers: [ "openai" ])
      key = create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-openrouter")

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(
        project: project,
        api_key: key.api_key,
        api_base_url: "https://openrouter.ai/api/v1"
      )
    end

    it "uses a fallback provider when the primary knowledge provider is unavailable" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      owner = project.effective_owner
      owner.settings.update!(kb_embedding_provider: "openai", kb_embedding_fallback_providers: [ "openrouter" ])
      create(:provider_state, user: owner, provider_name: "openai", rate_limited_until: 5.minutes.from_now)
      fallback_key = create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-openrouter")

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(
        project: project,
        api_key: fallback_key.api_key,
        api_base_url: "https://openrouter.ai/api/v1"
      )
    end

    it "is enqueued to the knowledge queue" do
      expect(described_class.new.queue_name).to eq("knowledge")
    end

    it "retries on EmbeddingError" do
      retries = described_class.rescue_handlers.select { |h| h[0] == "Knowledge::Embeddings::EmbeddingError" }

      expect(retries).not_to be_empty
    end

    it "retries on QdrantClient::ConnectionError" do
      retries = described_class.rescue_handlers.select { |h| h[0] == "QdrantClient::ConnectionError" }

      expect(retries).not_to be_empty
    end
  end
end
