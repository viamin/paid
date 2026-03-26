# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Provenance::AuditLog do
  let(:project) { create(:project) }

  describe ".record" do
    it "creates an audit event" do
      expect {
        described_class.record(
          event: :artifact_created,
          project: project,
          actor_type: "collector",
          actor_id: "collector_run_42",
          target_type: "KnowledgeArtifact",
          target_id: "789",
          details: { artifact_type: "route", identifier: "POST /api/users" }
        )
      }.to change(KnowledgeAuditEvent, :count).by(1)

      event = KnowledgeAuditEvent.last
      expect(event.event_type).to eq("artifact_created")
      expect(event.project).to eq(project)
      expect(event.actor_type).to eq("collector")
      expect(event.actor_id).to eq("collector_run_42")
      expect(event.target_type).to eq("KnowledgeArtifact")
      expect(event.target_id).to eq("789")
      expect(event.details).to eq({ "artifact_type" => "route", "identifier" => "POST /api/users" })
    end

    it "logs the event to Rails.logger" do
      allow(Rails.logger).to receive(:info)

      described_class.record(
        event: :artifact_staled,
        project: project,
        actor_type: "system",
        target_type: "KnowledgeArtifact",
        target_id: "123"
      )

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "knowledge.audit",
          event: "artifact_staled",
          project_id: project.id
        )
      )
    end

    it "handles symbol event types" do
      described_class.record(event: :chunk_embedded, project: project)
      expect(KnowledgeAuditEvent.last.event_type).to eq("chunk_embedded")
    end

    it "converts actor_id to string" do
      described_class.record(
        event: :artifact_created,
        project: project,
        actor_type: "collector",
        actor_id: 42
      )
      expect(KnowledgeAuditEvent.last.actor_id).to eq("42")
    end

    it "allows nil optional fields" do
      described_class.record(event: :artifact_created, project: project)

      event = KnowledgeAuditEvent.last
      expect(event.actor_type).to be_nil
      expect(event.actor_id).to be_nil
      expect(event.target_type).to be_nil
      expect(event.target_id).to be_nil
      expect(event.details).to eq({})
    end

    it "records all supported event types" do
      KnowledgeAuditEvent::EVENT_TYPES.each do |type|
        described_class.record(event: type, project: project)
      end

      expect(KnowledgeAuditEvent.count).to eq(KnowledgeAuditEvent::EVENT_TYPES.size)
    end

    it "does not raise on persistence failure" do
      allow(KnowledgeAuditEvent).to receive(:create).and_return(
        KnowledgeAuditEvent.new.tap { |e| e.errors.add(:base, "db error") }
      )
      allow(Rails.logger).to receive(:error)

      expect {
        described_class.record(event: :artifact_created, project: project)
      }.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(
        hash_including(message: "knowledge.audit.persist_failed")
      )
    end

    it "does not raise when create raises an exception" do
      allow(KnowledgeAuditEvent).to receive(:create).and_raise(ActiveRecord::ConnectionNotEstablished)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)

      result = nil
      expect {
        result = described_class.record(event: :artifact_created, project: project)
      }.not_to raise_error

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "knowledge.audit.persist_failed",
          error_class: "ActiveRecord::ConnectionNotEstablished"
        )
      )
    end

    it "uses presence for actor and target in log output" do
      allow(Rails.logger).to receive(:info)

      described_class.record(event: :artifact_created, project: project)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(actor: nil, target: nil)
      )
    end
  end

  describe ".record_batch" do
    it "bulk-inserts multiple audit events" do
      events = [
        { event: :chunk_embedded, project: project, actor_type: "embedding_pipeline",
          target_type: "KnowledgeChunk", target_id: "1", details: { model: "test" } },
        { event: :chunk_embedded, project: project, actor_type: "embedding_pipeline",
          target_type: "KnowledgeChunk", target_id: "2", details: { model: "test" } }
      ]

      expect { described_class.record_batch(events) }
        .to change(KnowledgeAuditEvent, :count).by(2)
    end

    it "logs each event" do
      allow(Rails.logger).to receive(:info)

      events = [
        { event: :chunk_embedded, project: project, actor_type: "embedding_pipeline",
          target_type: "KnowledgeChunk", target_id: "1", details: { model: "test" } }
      ]

      described_class.record_batch(events)

      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "knowledge.audit", event: "chunk_embedded")
      )
    end

    it "is a no-op for empty arrays" do
      expect { described_class.record_batch([]) }
        .not_to change(KnowledgeAuditEvent, :count)
    end

    it "falls back to per-row inserts when insert_all fails" do
      events = [
        { event: :chunk_embedded, project: project, actor_type: "embedding_pipeline",
          target_type: "KnowledgeChunk", target_id: "1", details: { model: "test" } },
        { event: :chunk_embedded, project: project, actor_type: "embedding_pipeline",
          target_type: "KnowledgeChunk", target_id: "2", details: { model: "test" } }
      ]

      allow(KnowledgeAuditEvent).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid.new("timeout"))
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)

      expect { described_class.record_batch(events) }
        .to change(KnowledgeAuditEvent, :count).by(2)

      expect(Rails.logger).to have_received(:error).with(
        hash_including(message: "knowledge.audit.persist_failed", rows_count: 2)
      )
    end
  end
end
