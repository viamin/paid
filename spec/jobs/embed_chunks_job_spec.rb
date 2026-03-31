# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbedChunksJob do
  let(:project) { create(:project) }

  describe "#perform" do
    it "calls the embedding pipeline without a project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)

      described_class.perform_now

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: nil, api_key: nil)
    end

    it "calls the embedding pipeline with a project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: project, api_key: nil)
    end

    it "resolves the API key from the project owner's provider API keys" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      owner = project.effective_owner
      key = create(:provider_api_key, user: owner, compatible_providers: %w[openai])

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: project, api_key: key.api_key)
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
