# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeArtifact do
  subject(:knowledge_artifact) { build(:knowledge_artifact) }

  describe "associations" do
    it { is_expected.to belong_to(:collector_run) }
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:knowledge_chunks).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:artifact_type) }
    it { is_expected.to validate_length_of(:artifact_type).is_at_most(100) }
    it { is_expected.to validate_presence_of(:collector_type) }
    it { is_expected.to validate_length_of(:collector_type).is_at_most(100) }
    it { is_expected.to validate_presence_of(:content_hash) }
    it { is_expected.to validate_length_of(:content_hash).is_at_most(64) }
    it { is_expected.to validate_uniqueness_of(:content_hash).scoped_to(:collector_run_id) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_length_of(:scope_path).is_at_most(1000) }
    it { is_expected.to validate_length_of(:identifier).is_at_most(500) }

    describe "project_matches_collector_run" do
      it "is invalid when project does not match collector run's project" do
        artifact = create(:knowledge_artifact)
        artifact.project = create(:project)
        expect(artifact).not_to be_valid
        expect(artifact.errors[:project]).to include("must match the collector run's project")
      end

      it "auto-assigns project from collector run when project is nil" do
        collector_run = create(:collector_run)
        artifact = build(:knowledge_artifact, collector_run: collector_run, project: nil)
        artifact.valid?
        expect(artifact.project_id).to eq(collector_run.project_version.project_id)
      end
    end
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

    describe ".stale" do
      it "returns only stale artifacts" do
        create(:knowledge_artifact, collector_run: collector_run, project: project)
        stale = create(:knowledge_artifact, :stale, collector_run: collector_run, project: project)

        expect(described_class.stale).to eq([ stale ])
      end
    end

    describe ".identifier_like" do
      it "returns artifacts with similar identifiers ranked by similarity" do
        matching = create(:knowledge_artifact, collector_run: collector_run, project: project,
          identifier: "UsersController")
        create(:knowledge_artifact, collector_run: collector_run, project: project,
          identifier: "PaymentGateway")

        results = described_class.identifier_like("UserController")
        expect(results).to include(matching)
      end

      it "returns empty when no identifiers are similar" do
        create(:knowledge_artifact, collector_run: collector_run, project: project,
          identifier: "PaymentGateway")

        expect(described_class.identifier_like("XyzAbcDef")).to be_empty
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
