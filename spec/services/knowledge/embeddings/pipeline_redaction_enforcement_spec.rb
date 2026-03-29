# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Embeddings::Pipeline do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }
  let(:artifact) { create(:knowledge_artifact, collector_run: collector_run, project: project) }

  let(:vector) { Array.new(3072, 0.1) }
  let(:embed_result) { Knowledge::Embeddings::Generate::Result.new(vector: vector, token_count: 5) }
  let(:generator) { instance_double(Knowledge::Embeddings::Generate, model: "text-embedding-3-large") }

  before do
    allow(generator).to receive(:call).and_return([ embed_result ])
  end

  describe "redaction scan enforcement" do
    it "raises when chunk has not been redaction-scanned" do
      create(:knowledge_chunk,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil,
        redaction_scanned_at: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      expect { described_class.call(generator: generator) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /Refusing to embed/)
      expect(Knowledge::Qdrant::PointSync).not_to have_received(:upsert_chunk!)
    end

    it "allows unscanned chunks when SKIP_REDACTION_SCAN=1" do
      create(:knowledge_chunk,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil,
        redaction_scanned_at: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
      allow(Rails.logger).to receive(:warn)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SKIP_REDACTION_SCAN").and_return("1")
      allow(ENV).to receive(:fetch).and_call_original

      result = described_class.call(generator: generator)
      expect(result[:chunks_embedded]).to eq(1)

      expect(Rails.logger).to have_received(:warn).with(hash_including(
        message: "knowledge.embeddings.unscanned_chunks"
      ))
    end

    it "processes chunks that have been redaction-scanned without warning" do
      create(:knowledge_chunk, :redaction_scanned,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
      allow(Rails.logger).to receive(:warn)

      result = described_class.call(generator: generator)

      expect(Rails.logger).not_to have_received(:warn)
      expect(result[:chunks_embedded]).to eq(1)
    end

    it "includes unscanned chunk IDs in the error" do
      chunk = create(:knowledge_chunk,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil,
        redaction_scanned_at: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      expect { described_class.call(generator: generator) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /#{chunk.id}/)
    end
  end
end
