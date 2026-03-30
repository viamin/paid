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

  describe ".call" do
    let!(:chunk) do
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "active", embedding_model: nil)
    end

    it "generates embeddings for unembedded active chunks" do
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      result = described_class.call(generator: generator)

      expect(result[:chunks_embedded]).to eq(1)
      expect(result[:total_tokens]).to eq(5)
      expect(result[:estimated_cost]).to be_a(Numeric)
      expect(result[:duration_seconds]).to be_a(Numeric)
    end

    it "upserts vectors to Qdrant" do
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      described_class.call(generator: generator)

      expect(Knowledge::Qdrant::PointSync).to have_received(:upsert_chunk!).with(chunk, vector: vector)
    end

    it "records embedding_model on processed chunks" do
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      described_class.call(generator: generator)

      expect(chunk.reload.embedding_model).to eq("text-embedding-3-large")
    end

    it "is idempotent — skips already-embedded chunks" do
      chunk.update!(embedding_model: "text-embedding-3-large")
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      result = described_class.call(generator: generator)

      expect(result[:chunks_embedded]).to eq(0)
      expect(Knowledge::Qdrant::PointSync).not_to have_received(:upsert_chunk!)
    end

    it "skips non-active chunks" do
      chunk.update!(status: "stale")
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      result = described_class.call(generator: generator)

      expect(result[:chunks_embedded]).to eq(0)
    end

    it "filters by project when specified" do
      other_project = create(:project)
      other_version = create(:project_version, project: other_project)
      other_run = create(:collector_run, project_version: other_version)
      other_artifact = create(:knowledge_artifact, collector_run: other_run, project: other_project)
      create(:knowledge_chunk, knowledge_artifact: other_artifact, project: other_project, status: "active", embedding_model: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      result = described_class.call(project: project, generator: generator)

      expect(result[:chunks_embedded]).to eq(1)
    end

    it "respects configurable batch size" do
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

      pipeline = described_class.new(batch_size: 1, generator: generator)
      result = pipeline.call

      expect(result[:chunks_embedded]).to eq(1)
    end

    it "raises ArgumentError for zero batch size" do
      expect { described_class.new(batch_size: 0, generator: generator) }
        .to raise_error(ArgumentError, /batch_size must be a positive integer/)
    end

    it "raises ArgumentError for negative batch size" do
      expect { described_class.new(batch_size: -1, generator: generator) }
        .to raise_error(ArgumentError, /batch_size must be a positive integer/)
    end

    it "raises EmbeddingError when result count mismatches chunk count" do
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
      allow(generator).to receive(:call).and_return([]) # 0 results for 1 chunk

      expect { described_class.call(generator: generator) }
        .to raise_error(Knowledge::Embeddings::EmbeddingError, /Embedding count mismatch/)
    end

    it "logs completion with cost info" do
      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
      allow(Rails.logger).to receive(:info)

      described_class.call(generator: generator)

      expect(Rails.logger).to have_received(:info).with(hash_including(
        message: "knowledge.embeddings.pipeline_completed",
        chunks_embedded: 1
      ))
    end

    context "with redaction" do
      it "marks fully-redacted chunks as redacted and skips embedding" do
        chunk.update!(content: "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn")
        allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

        result = described_class.call(generator: generator)

        chunk.reload
        expect(chunk.status).to eq("redacted")
        expect(chunk.content).to include("[REDACTED:")
        expect(chunk.content).not_to include("ghp_")
        expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest(chunk.content))
        expect(result[:chunks_embedded]).to eq(0)
        expect(Knowledge::Qdrant::PointSync).not_to have_received(:upsert_chunk!)
      end

      it "redacts partially-sensitive chunks and still embeds them" do
        sensitive_content = "This is a long paragraph of normal text. Contact admin@example.com for help with the system."
        chunk.update!(content: sensitive_content)
        allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)

        result = described_class.call(generator: generator)

        chunk.reload
        expect(chunk.content).to include("[REDACTED:email]")
        expect(chunk.content).not_to include("admin@example.com")
        expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest(chunk.content))
        expect(chunk.status).to eq("active")
        expect(result[:chunks_embedded]).to eq(1)
        expect(Knowledge::Qdrant::PointSync).to have_received(:upsert_chunk!)
      end

      it "emits audit events for redacted chunks" do
        chunk.update!(content: "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn")
        allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
        allow(Knowledge::Provenance::AuditLog).to receive(:record_batch)

        described_class.call(generator: generator)

        expect(Knowledge::Provenance::AuditLog).to have_received(:record_batch).with(
          array_including(hash_including(event: :chunk_redacted, details: hash_including(fully_redacted: true)))
        )
      end
    end
  end
end
