# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Redaction::Reembed do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }
  let(:artifact) { create(:knowledge_artifact, collector_run: collector_run, project: project) }
  let(:vector) { Array.new(3072, 0.1) }
  let(:embed_result) { Knowledge::Embeddings::Generate::Result.new(vector: vector, token_count: 5) }
  let(:generator) { instance_double(Knowledge::Embeddings::Generate, model: "text-embedding-3-large") }

  before do
    allow(generator).to receive(:call).and_return([ embed_result ])
    allow(Knowledge::Qdrant::PointSync).to receive(:upsert_chunk!)
  end

  def build_chunk(content:, status: "active", embedding_model: "text-embedding-3-large",
    redaction_scanned_at: 1.hour.ago, knowledge_artifact_param: nil, project_param: project)
    art = knowledge_artifact_param || artifact
    create(:knowledge_chunk, knowledge_artifact: art, project: project_param, status: status,
      embedding_model: embedding_model, content: content, redaction_scanned_at: redaction_scanned_at)
  end

  describe "initialization" do
    it "requires a generator" do
      expect {
        described_class.new(project: project)
      }.to raise_error(ArgumentError, /generator/)
    end

    it "rejects passing both chunk_ids and since" do
      expect {
        described_class.new(project: project, generator: generator, since: 1.hour.ago, chunk_ids: [ "abc" ])
      }.to raise_error(ArgumentError, /Pass either `since` or `chunk_ids`/)
    end

    it "falls back to the default batch size when batch_size is zero" do
      reembed = described_class.new(project: project, generator: generator, batch_size: 0)
      expect(reembed.batch_size).to eq(described_class::DEFAULT_BATCH_SIZE)
    end

    it "falls back to default actor when none is provided" do
      reembed = described_class.new(project: project, generator: generator, actor: nil)
      expect(reembed.actor).to eq({ type: "system" })
    end
  end

  describe ".call" do
    let(:actor) { { type: "operator", id: "42" } }

    it "re-embeds chunks whose content was retroactively scrubbed" do
      chunk = build_chunk(content: "User bob@example.com signed in via SSO.")

      result = described_class.new(project: project, generator: generator, actor: actor).call

      expect(result.reembedded_count).to eq(1)
      expect(result.skipped_count).to eq(0)
      expect(Knowledge::Qdrant::PointSync).to have_received(:upsert_chunk!).with(chunk, vector: vector)
    end

    it "records a chunk_embedded audit event with reembedded: true" do
      build_chunk(content: "User bob@example.com signed in via SSO.")

      expect {
        described_class.new(project: project, generator: generator, actor: actor).call
      }.to change { KnowledgeAuditEvent.by_event_type("chunk_embedded").count }.by(1)

      event = KnowledgeAuditEvent.by_event_type("chunk_embedded").last
      expect(event.actor_type).to eq("operator")
      expect(event.actor_id).to eq("42")
      expect(event.details).to include("model" => "text-embedding-3-large", "reembedded" => true)
    end

    it "skips chunks that are fully redacted" do
      build_chunk(content: "[REDACTED:github_token]", status: "redacted")
      build_chunk(content: "User bob@example.com signed in via SSO.")

      result = described_class.new(project: project, generator: generator, actor: actor).call

      expect(result.reembedded_count).to eq(1)
    end

    it "skips chunks that were never redaction-scanned by default" do
      build_chunk(content: "User charlie@example.com signed in via SSO.", redaction_scanned_at: nil)

      result = described_class.new(project: project, generator: generator, actor: actor).call

      expect(result.reembedded_count).to eq(0)
    end

    it "honors a custom since threshold" do
      active_chunk = build_chunk(content: "User bob@example.com signed in via SSO.")
      build_chunk(content: "User dave@example.com signed in via SSO.", redaction_scanned_at: 2.days.ago)

      result = described_class.new(
        project: project,
        generator: generator,
        actor: actor,
        since: 6.hours.ago
      ).call

      expect(result.reembedded_count).to eq(1)
      expect(Knowledge::Qdrant::PointSync).to have_received(:upsert_chunk!).with(active_chunk, vector: vector)
    end

    it "honors an explicit chunk_ids list" do
      active_chunk = build_chunk(content: "User bob@example.com signed in via SSO.")
      other_chunk = build_chunk(content: "User erin@example.com signed in via SSO.",
        redaction_scanned_at: 1.minute.ago)

      result = described_class.new(
        project: project,
        generator: generator,
        actor: actor,
        chunk_ids: [ active_chunk.id ]
      ).call

      expect(result.reembedded_count).to eq(1)
      expect(Knowledge::Qdrant::PointSync).to have_received(:upsert_chunk!).with(active_chunk, vector: vector)
      expect(Knowledge::Qdrant::PointSync).not_to have_received(:upsert_chunk!).with(other_chunk, vector: vector)
    end

    it "raises EmbeddingError when the embedding count mismatches" do
      build_chunk(content: "User bob@example.com signed in via SSO.")
      allow(generator).to receive(:call).and_return([])

      expect {
        described_class.new(project: project, generator: generator, actor: actor).call
      }.to raise_error(Knowledge::Embeddings::EmbeddingError, /Reembed batch mismatch/)
    end

    it "skips chunks when the generator returns nil for that chunk" do
      build_chunk(content: "User bob@example.com signed in via SSO.")
      allow(generator).to receive(:call).and_return([ nil ])

      result = described_class.new(project: project, generator: generator, actor: actor).call

      expect(result.reembedded_count).to eq(0)
      expect(result.skipped_count).to eq(1)
    end

    it "is a no-op when no chunks are eligible" do
      result = described_class.new(project: project, generator: generator, actor: actor).call

      expect(result.reembedded_count).to eq(0)
      expect(result.skipped_count).to eq(0)
      expect(Knowledge::Qdrant::PointSync).not_to have_received(:upsert_chunk!)
    end

    it "is scoped to the project" do
      active_chunk = build_chunk(content: "User bob@example.com signed in via SSO.")
      other_project = create(:project)
      other_version = create(:project_version, project: other_project)
      other_run = create(:collector_run, project_version: other_version)
      other_artifact = create(:knowledge_artifact, collector_run: other_run, project: other_project)
      build_chunk(content: "User frank@example.com signed in via SSO.",
        knowledge_artifact_param: other_artifact, project_param: other_project,
        redaction_scanned_at: 1.minute.ago)

      described_class.new(project: project, generator: generator, actor: actor).call

      expect(Knowledge::Qdrant::PointSync).to have_received(:upsert_chunk!).with(active_chunk, vector: vector)
    end
  end
end
