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

  describe "mandatory redaction scan" do
    it "raises EmbeddingError when chunk has not been redaction-scanned" do
      create(:knowledge_chunk,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil,
        redaction_scanned_at: nil)

      expect { described_class.call(generator: generator) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /not scanned for redaction/)
    end

    it "processes chunks that have been redaction-scanned" do
      create(:knowledge_chunk, :redaction_scanned,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      result = described_class.call(generator: generator)

      expect(result[:chunks_embedded]).to eq(1)
    end

    it "identifies unscanned chunks by ID in the error message" do
      chunk = create(:knowledge_chunk,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil,
        redaction_scanned_at: nil)

      expect { described_class.call(generator: generator) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /#{chunk.id}/)
    end
  end
end
