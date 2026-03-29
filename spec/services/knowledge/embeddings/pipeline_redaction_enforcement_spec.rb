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
    it "warns when chunk has not been redaction-scanned but still embeds" do
      create(:knowledge_chunk,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil,
        redaction_scanned_at: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
      allow(Rails.logger).to receive(:warn)

      result = described_class.call(generator: generator)

      expect(Rails.logger).to have_received(:warn).with(hash_including(
        message: "knowledge.embeddings.unscanned_chunks"
      ))
      expect(result[:chunks_embedded]).to eq(1)
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

    it "includes unscanned chunk IDs in the warning" do
      chunk = create(:knowledge_chunk,
        knowledge_artifact: artifact,
        project: project,
        status: "active",
        embedding_model: nil,
        redaction_scanned_at: nil)

      allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
      allow(Rails.logger).to receive(:warn)

      described_class.call(generator: generator)

      expect(Rails.logger).to have_received(:warn).with(hash_including(
        example_chunk_ids: chunk.id.to_s
      ))
    end
  end
end
