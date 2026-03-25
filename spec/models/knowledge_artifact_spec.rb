# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeArtifact do
  describe "associations" do
    it { is_expected.to belong_to(:collector_run) }
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:knowledge_chunks).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:artifact_type) }
    it { is_expected.to validate_length_of(:artifact_type).is_at_most(100) }
    it { is_expected.to validate_presence_of(:content_hash) }
    it { is_expected.to validate_length_of(:content_hash).is_at_most(64) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_length_of(:scope_path).is_at_most(1000) }
    it { is_expected.to validate_length_of(:identifier).is_at_most(500) }
  end

  describe "scopes" do
    let!(:active_artifact) { create(:knowledge_artifact, status: "active") }
    let!(:stale_artifact) { create(:knowledge_artifact, status: "stale") }

    describe ".active" do
      it "returns active artifacts" do
        expect(described_class.active).to contain_exactly(active_artifact)
      end
    end

    describe ".stale" do
      it "returns stale artifacts" do
        expect(described_class.stale).to contain_exactly(stale_artifact)
      end
    end

    describe ".by_type" do
      it "returns artifacts of the given type" do
        expect(described_class.by_type("route")).to contain_exactly(active_artifact, stale_artifact)
      end
    end
  end
end
