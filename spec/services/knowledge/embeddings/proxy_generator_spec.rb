# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Embeddings::ProxyGenerator do
  let(:project) { create(:project) }
  let(:provider_configs) do
    [
      Knowledge::ProviderConfiguration::Result.new(provider: "openrouter"),
      Knowledge::ProviderConfiguration::Result.new(provider: "openai")
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

  describe "#call" do
    it "calls the proxy-backed generator with knowledge-run credentials" do
      allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([ result ])

      results = generator.call(texts: [ "hello" ])
      generator.close

      expect(results).to eq([ result ])
      expect(Knowledge::Embeddings::Generate).to have_received(:call).with(
        texts: [ "hello" ],
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

      expect(knowledge_run).not_to have_received(:update!).with(hash_including(final_provider: "openrouter"))
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
