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
    it { is_expected.to validate_presence_of(:content_hash) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(KnowledgeArtifact::STATUSES) }
  end

  describe "scopes" do
    let(:project) { create(:project) }
    let(:project_version) { create(:project_version, project: project) }
    let(:collector_run) { create(:collector_run, project_version: project_version) }

    describe ".active" do
      it "returns only active artifacts" do
        active = create(:knowledge_artifact, collector_run: collector_run, project: project)
        create(:knowledge_artifact, :stale, collector_run: collector_run, project: project)

        expect(described_class.active).to eq([ active ])
      end
    end

    describe ".by_type" do
      it "filters by artifact type" do
        route = create(:knowledge_artifact, collector_run: collector_run, project: project, artifact_type: "route")
        create(:knowledge_artifact, collector_run: collector_run, project: project, artifact_type: "symbol")

        expect(described_class.by_type("route")).to eq([ route ])
      end
    end
  end
end
