# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeChunk do
  describe "associations" do
    it { is_expected.to belong_to(:knowledge_artifact) }
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:source_links).dependent(:destroy) }
    it { is_expected.to have_many(:target_links).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:chunk_type) }
    it { is_expected.to validate_inclusion_of(:chunk_type).in_array(described_class::CHUNK_TYPES) }
    it { is_expected.to validate_presence_of(:content) }
    it { is_expected.to validate_presence_of(:content_hash) }
    it { is_expected.to validate_length_of(:content_hash).is_at_most(64) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    describe "project_matches_knowledge_artifact_project" do
      it "is invalid when project does not match knowledge artifact's project" do
        chunk = build(:knowledge_chunk)
        chunk.project = create(:project)
        expect(chunk).not_to be_valid
        expect(chunk.errors[:project]).to include("must match knowledge artifact's project")
      end
    end
  end

  describe "scopes" do
    let!(:active_chunk) { create(:knowledge_chunk, status: "active", embedding_model: "text-embedding-3-large") }
    let!(:stale_chunk) { create(:knowledge_chunk, status: "stale") }
    let!(:active_no_embedding) { create(:knowledge_chunk, status: "active", embedding_model: nil) }

    describe ".active" do
      it "returns only active chunks" do
        expect(described_class.active).to contain_exactly(active_chunk, active_no_embedding)
        expect(described_class.active).not_to include(stale_chunk)
      end
    end

    describe ".embeddable" do
      it "returns active chunks with an embedding model" do
        expect(described_class.embeddable).to contain_exactly(active_chunk)
      end
    end

    describe ".by_project" do
      it "returns chunks for a given project" do
        expect(described_class.by_project(active_chunk.project_id)).to include(active_chunk)
      end
    end

    describe ".ordered" do
      it "returns chunks ordered by sequence" do
        artifact = create(:knowledge_artifact)
        second = create(:knowledge_chunk, knowledge_artifact: artifact, project: artifact.project, sequence: 1)
        first = create(:knowledge_chunk, knowledge_artifact: artifact, project: artifact.project, sequence: 0)
        expect(artifact.knowledge_chunks.ordered).to eq([ first, second ])
      end
    end
  end
end
