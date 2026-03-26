# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbedChunksJob do
  let(:project) { create(:project) }

  describe "#perform" do
    it "calls the embedding pipeline without a project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)

      described_class.perform_now

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: nil)
    end

    it "calls the embedding pipeline with a project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: project)
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
