# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbedChunksJob do
  let(:project) { create(:project) }

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  describe "#perform" do
    it "calls the embedding pipeline without a project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)

      described_class.perform_now

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: nil)
    end

    it "skips the embedding pipeline when no runner is configured for the project" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      allow(project).to receive(:semantic_search_available?).and_return(false)
      allow(Project).to receive(:find).with(project.id).and_return(project)

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).not_to have_received(:call)
    end

    it "runs the embedding pipeline for a project with a configured runner" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      owner = project.effective_owner
      owner.settings.update!(kb_embedding_runner: "openrouter", kb_embedding_fallback_runners: [ "openai" ])
      create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-openrouter")

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: project)
    end

    it "runs the embedding pipeline when only a platform OpenAI credential is available" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      owner = project.effective_owner
      owner.settings.update!(kb_embedding_runner: "openai", kb_embedding_fallback_runners: [])
      allow(Rails.application.credentials).to receive(:dig).with(:llm, :openai_api_key).and_return("sk-platform")

      described_class.perform_now(project.id)

      expect(Knowledge::Embeddings::Pipeline).to have_received(:call).with(project: project)
    end

    it "uses a fallback runner when the primary knowledge runner is unavailable" do
      allow(Knowledge::Embeddings::Pipeline).to receive(:call)
      owner = project.effective_owner
      owner.settings.update!(kb_embedding_runner: "openai", kb_embedding_fallback_runners: [ "openrouter" ])
      create(:runner_state, user: owner, runner_name: "openai", rate_limited_until: 5.minutes.from_now)
      create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-openrouter")

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

    it "busts the artifact counts and OKF export availability caches when a project is provided" do
      with_memory_cache do
        allow(Knowledge::Embeddings::Pipeline).to receive(:call)
        Rails.cache.write(KnowledgeArtifact.artifact_counts_cache_key(project.id), { "route" => 3 })
        Rails.cache.write(KnowledgeArtifact.okf_export_available_cache_key(project.id), true)

        described_class.perform_now(project.id)

        expect(Rails.cache.read(KnowledgeArtifact.artifact_counts_cache_key(project.id))).to be_nil
        expect(Rails.cache.read(KnowledgeArtifact.okf_export_available_cache_key(project.id))).to be_nil
      end
    end

    it "still busts the caches when the embedding pipeline raises" do
      with_memory_cache do
        allow(project).to receive(:semantic_search_available?).and_return(true)
        allow(Knowledge::Embeddings::Pipeline).to receive(:call)
          .and_raise(Knowledge::Embeddings::EmbeddingError, "boom")
        Rails.cache.write(KnowledgeArtifact.artifact_counts_cache_key(project.id), { "route" => 3 })

        begin
          described_class.perform_now(project.id)
        rescue Knowledge::Embeddings::EmbeddingError
          # Expected — retry_on re-raises after exhausting attempts.
        end

        expect(Rails.cache.read(KnowledgeArtifact.artifact_counts_cache_key(project.id))).to be_nil
      end
    end
  end
end
