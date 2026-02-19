# frozen_string_literal: true

require "rails_helper"

RSpec.describe SemanticSearch::GenerateEmbeddings do
  let(:project) { create(:project) }

  describe ".call" do
    it "processes chunks without embeddings" do
      create(:code_chunk, project: project, embedding: nil)

      stats = described_class.call(project: project)

      # Currently returns nil embeddings until a provider is configured,
      # so chunks remain without embeddings (counted as failed)
      expect(stats[:generated] + stats[:failed]).to eq(1)
    end

    it "respects batch_size" do
      3.times { create(:code_chunk, project: project, embedding: nil) }

      stats = described_class.call(project: project, batch_size: 2)

      expect(stats[:generated] + stats[:failed]).to eq(2)
    end

    it "returns zero stats when all chunks have embeddings" do
      # No chunks without embeddings to process
      stats = described_class.call(project: project)

      expect(stats[:generated]).to eq(0)
      expect(stats[:failed]).to eq(0)
    end
  end
end
