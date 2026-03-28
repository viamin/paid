# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::DecisionRecordCollector do
  subject(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run,
      options: {}
    )
  end

  let(:project) { create(:project) }
  let(:project_version) { Struct.new(:id).new(1) }
  let(:collector_run) { Struct.new(:id).new(1) }

  describe "#collector_type" do
    it "returns decision_record" do
      expect(collector.collector_type).to eq("decision_record")
    end
  end

  describe "#collect" do
    it "returns empty array when no decision records exist" do
      expect(collector.collect).to eq([])
    end

    context "with active decision records" do
      let!(:record) do
        create(:decision_record,
          project: project,
          title: "Use JWT for auth",
          summary: "JWT chosen for API auth.",
          context: "Session auth was insufficient.",
          decision: "Implement JWT auth.",
          consequences: "Clients must refresh tokens.",
          tags: %w[auth api],
          status: "active")
      end

      let(:artifacts) { collector.collect }
      let(:artifact) { artifacts.first }

      it "returns one artifact per record" do
        expect(artifacts.length).to eq(1)
      end

      it "sets artifact_type to decision_record" do
        expect(artifact[:artifact_type]).to eq("decision_record")
      end

      it "sets scope_path using the record id" do
        expect(artifact[:scope_path]).to eq("decisions/#{record.id}")
      end

      it "uses the title as identifier" do
        expect(artifact[:identifier]).to eq("Use JWT for auth")
      end

      it "includes metadata with record attributes" do
        expect(artifact[:metadata]).to include(
          decision_record_id: record.id,
          status: "active",
          tags: %w[auth api]
        )
      end

      it "builds content with title and sections" do
        expect(artifact[:content]).to include("# Use JWT for auth")
        expect(artifact[:content]).to include("## Summary")
        expect(artifact[:content]).to include("## Decision")
      end

      it "includes context section when present" do
        expect(artifact[:content]).to include("## Context")
        expect(artifact[:content]).to include("Session auth was insufficient.")
      end

      it "includes consequences section when present" do
        expect(artifact[:content]).to include("## Consequences")
        expect(artifact[:content]).to include("Clients must refresh tokens.")
      end

      it "produces a summary chunk" do
        summary_chunk = artifact[:chunks].find { |c| c[:chunk_type] == "summary" }
        expect(summary_chunk).to be_present
        expect(summary_chunk[:content]).to include("Use JWT for auth")
      end

      it "produces a context chunk" do
        context_chunk = artifact[:chunks].find { |c| c[:chunk_type] == "context" }
        expect(context_chunk).to be_present
        expect(context_chunk[:content]).to eq("Session auth was insufficient.")
      end

      it "produces evidence chunks for decision and consequences" do
        evidence_chunks = artifact[:chunks].select { |c| c[:chunk_type] == "evidence" }
        expect(evidence_chunks.length).to eq(2)
      end

      it "sets scope_tags from record tags" do
        artifact[:chunks].each do |chunk|
          expect(chunk[:scope_tags]).to eq(%w[auth api])
        end
      end
    end

    context "with optional fields absent" do
      let(:record) do
        create(:decision_record,
          project: project,
          context: nil,
          consequences: nil,
          tags: [])
      end

      let(:artifacts) { collector.collect }
      let(:artifact) { artifacts.first }

      before { record }

      it "omits context section from content" do
        expect(artifact[:content]).not_to include("## Context")
      end

      it "omits consequences section from content" do
        expect(artifact[:content]).not_to include("## Consequences")
      end

      it "does not produce a context chunk" do
        context_chunks = artifact[:chunks].select { |c| c[:chunk_type] == "context" }
        expect(context_chunks).to be_empty
      end

      it "produces only one evidence chunk (decision only)" do
        evidence_chunks = artifact[:chunks].select { |c| c[:chunk_type] == "evidence" }
        expect(evidence_chunks.length).to eq(1)
      end
    end

    context "with superseded records" do
      before do
        create(:decision_record, :superseded, project: project)
      end

      it "excludes superseded records" do
        artifacts = collector.collect
        statuses = artifacts.map { |a| a[:metadata][:status] }
        expect(statuses).not_to include("superseded")
      end
    end

    context "with draft records" do
      before do
        create(:decision_record, :draft, project: project)
      end

      it "includes draft records" do
        expect(collector.collect.length).to eq(1)
      end
    end

    context "with records from another project" do
      before do
        create(:decision_record) # different project
      end

      it "excludes records from other projects" do
        expect(collector.collect).to be_empty
      end
    end
  end
end
