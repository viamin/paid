# frozen_string_literal: true

require "rails_helper"

RSpec.describe IndexProjectJob do
  let(:project) { create(:project) }
  let(:repo_path) { "/tmp/test_repo" }

  describe "#perform" do
    it "calls SemanticSearch::IndexProject and GenerateEmbeddings" do
      index_stats = { indexed: 5, skipped: 0, removed: 0 }
      embed_stats = { generated: 0, failed: 5 }

      allow(SemanticSearch::IndexProject).to receive(:call)
        .with(project: project, repo_path: repo_path)
        .and_return(index_stats)

      allow(SemanticSearch::GenerateEmbeddings).to receive(:call)
        .with(project: project)
        .and_return(embed_stats)

      described_class.new.perform(project.id, repo_path: repo_path)

      expect(SemanticSearch::IndexProject).to have_received(:call).once
      expect(SemanticSearch::GenerateEmbeddings).to have_received(:call).once
    end
  end
end
