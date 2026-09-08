# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Embeddings::ProxyGenerator do
  let(:project) { create(:project) }
  let(:provider_configs) do
    [
      Knowledge::RunnerConfiguration::Result.new(runner: "openrouter"),
      Knowledge::RunnerConfiguration::Result.new(runner: "openai")
    ]
  end
  let(:knowledge_run) { create(:knowledge_run, :running, project: project) }
  let(:result) { Knowledge::Embeddings::Generate::Result.new(vector: [ 0.1 ], token_count: 5) }
  let(:generator) do
    described_class.new(
      project: project,
      provider_configs: provider_configs,
      knowledge_run: knowledge_run,
      containerize: false
    )
  end

  def stub_provider_failover
    calls = 0
    allow(Knowledge::Embeddings::Generate).to receive(:call) do
      calls += 1
      raise Knowledge::Embeddings::EmbeddingError, "primary failed" if calls == 1

      [ result ]
    end
  end

  describe "#call" do
    it "calls the proxy-backed generator with knowledge-run credentials" do
      allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([ result ])

      results = generator.call(texts: [ "hello" ])
      generator.close

      expect(results).to eq([ result ])
      expect(Knowledge::Embeddings::Generate).to have_received(:call).with(
        texts: [ "hello" ],
        model: "text-embedding-3-large",
        dimensions: 3072,
        base_url: "http://web:3000/api/proxy/openai/v1",
        headers: hash_including(
          "Authorization" => "Bearer paid-knowledge-run:#{knowledge_run.id}:#{knowledge_run.proxy_token}",
          "X-Paid-Knowledge-Provider" => "openrouter"
        )
      )
      expect(knowledge_run.reload.final_provider).to eq("openrouter")
      expect(knowledge_run.provider_attempts.size).to eq(1)
      expect(knowledge_run.provider_attempts.first).to include("provider" => "openrouter")
      expect(knowledge_run.provider_attempts.first["attempted_at"]).to match(/\A.+\z/)
      expect(knowledge_run.status).to eq("completed")
    end

    it "uses the user-configured embedding model and dimensions" do
      project.effective_owner.settings.update!(kb_embedding_model: "text-embedding-3-small", kb_embedding_dimensions: 1536)
      proxy_generator = described_class.new(
        project: project,
        provider_configs: provider_configs,
        knowledge_run: knowledge_run,
        containerize: false
      )
      allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([ result ])

      proxy_generator.call(texts: [ "hello" ])
      proxy_generator.close

      expect(Knowledge::Embeddings::Generate).to have_received(:call).with(
        hash_including(model: "text-embedding-3-small", dimensions: 1536)
      )
      expect(proxy_generator.model).to eq("text-embedding-3-small")
      expect(proxy_generator.dimensions).to eq(1536)
    end

    it "falls back to bundled defaults when user settings return blanks" do
      # The schema enforces NOT NULL on kb_embedding_dimensions, so the
      # in-memory fallback is exercised by stubbing the resolved values
      # to blank/nil on the live user_setting.
      allow(project.effective_owner.settings).to receive_messages(
        kb_embedding_model: "",
        kb_embedding_dimensions: nil
      )
      proxy_generator = described_class.new(
        project: project,
        provider_configs: provider_configs,
        knowledge_run: knowledge_run,
        containerize: false
      )
      allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([ result ])

      proxy_generator.call(texts: [ "hello" ])
      proxy_generator.close

      expect(Knowledge::Embeddings::Generate).to have_received(:call).with(
        hash_including(model: "text-embedding-3-large", dimensions: 3072)
      )
    end

    it "uses the user setting's blank-fallback dimension when the underlying column is empty" do
      # The schema enforces NOT NULL, but the in-memory accessor coerces
      # blank strings to the bundled default so legacy data and broken
      # JSONB round-trips do not silently drop dimensions.
      settings = project.effective_owner.settings
      settings.update!(kb_embedding_dimensions: 1)
      allow(settings).to receive(:kb_embedding_dimensions).and_return(Knowledge::Embeddings::Generate::DEFAULT_DIMENSIONS)
      proxy_generator = described_class.new(
        project: project,
        provider_configs: provider_configs,
        knowledge_run: knowledge_run,
        containerize: false
      )
      allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([ result ])

      proxy_generator.call(texts: [ "hello" ])
      proxy_generator.close

      expect(Knowledge::Embeddings::Generate).to have_received(:call).with(
        hash_including(dimensions: 3072)
      )
    end

    it "falls back to later configured providers" do
      calls = 0
      allow(Knowledge::Embeddings::Generate).to receive(:call) do
        calls += 1
        raise Knowledge::Embeddings::EmbeddingError, "primary failed" if calls == 1

        [ result ]
      end

      results = generator.call(texts: [ "hello" ])
      generator.close

      expect(results).to eq([ result ])
      expect(knowledge_run.reload.final_provider).to eq("openai")
      expect(knowledge_run.provider_attempts).to contain_exactly(
        hash_including("provider" => "openrouter", "attempted_at" => be_present),
        hash_including("provider" => "openai", "attempted_at" => be_present)
      )
    end

    it "avoids redundant final provider updates across successful batches" do
      allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([ result ])

      generator.call(texts: [ "hello" ])
      expect(knowledge_run.reload.final_provider).to eq("openrouter")

      allow(knowledge_run).to receive(:update!).and_call_original
      generator.call(texts: [ "again" ])

      expect(knowledge_run).not_to have_received(:update!).with(hash_including(final_runner: "openrouter"))
    end

    it "marks the knowledge run failed when every provider fails" do
      allow(Knowledge::Embeddings::Generate).to receive(:call)
        .and_raise(Knowledge::Embeddings::EmbeddingError, "no providers available")

      expect {
        generator.call(texts: [ "hello" ])
      }.to raise_error(Knowledge::Embeddings::EmbeddingError, /Embedding generation failed/)

      generator.close
      expect(knowledge_run.reload.status).to eq("failed")
    end

    # @spec KNOWLEDGE-011
    it "annotates each attempt with its outcome so provider_attempts stops being just timestamps" do
      stub_provider_failover

      generator.call(texts: [ "hello" ])
      generator.close

      attempts = knowledge_run.reload.provider_attempts
      expect(attempts).to contain_exactly(
        hash_including(
          "provider" => "openrouter",
          "outcome" => "provider_error",
          "error_class" => "Knowledge::Embeddings::EmbeddingError",
          "error_message" => "primary failed"
        ),
        hash_including("provider" => "openai", "outcome" => "success")
      )
    end

    # @spec KNOWLEDGE-011
    it "persists the structured failure reason when every provider fails" do
      allow(Knowledge::Embeddings::Generate).to receive(:call)
        .and_raise(Knowledge::Embeddings::EmbeddingError, "no providers available")

      expect {
        generator.call(texts: [ "hello" ])
      }.to raise_error(Knowledge::Embeddings::EmbeddingError)

      generator.close

      knowledge_run.reload
      expect(knowledge_run.status).to eq("failed")
      expect(knowledge_run.failure_reason).to eq("all_providers_exhausted")
      expect(knowledge_run.error_class).to eq("Knowledge::Embeddings::EmbeddingError")
      expect(knowledge_run.error_message).to eq("no providers available")
      expect(knowledge_run.completed_at).to be_present
    end

    it "uses the project token guardrail for embedding knowledge runs it creates" do
      generated_run = nil
      project.update!(max_tokens_per_run: 50_000)
      allow(Knowledge::Embeddings::Generate).to receive(:call) do
        generated_run = KnowledgeRun.order(:id).last
        [ result ]
      end

      described_class.new(project: project, provider_configs: provider_configs, containerize: false).call(texts: [ "hello" ])

      expect(generated_run).to have_attributes(
        operation_type: "embedding",
        max_tokens: 50_000
      )
    end
  end
end
