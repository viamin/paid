# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::Synthesize do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:session) do
    s = create(:context_intake_session, :completed, project: project, started_by: user)
    create(:context_intake_response, :answered,
      context_intake_session: s,
      question_key: "product_description",
      question_text: "What does this product do?",
      answer_text: "It automates software development.",
      section: "product_purpose",
      sequence: 0)
    create(:context_intake_response, :answered,
      context_intake_session: s,
      question_key: "primary_users",
      question_text: "Who are the primary users?",
      answer_text: "Engineering teams.",
      section: "target_users",
      sequence: 0)
    s
  end

  describe ".call" do
    it "creates knowledge artifacts for answered sections" do
      result = described_class.call(session: session)

      expect(result[:artifacts_count]).to eq(2)
      artifacts = KnowledgeArtifact.for_project(project).active.by_type("business_context")
      expect(artifacts.count).to eq(2)
    end

    it "creates a collector run" do
      result = described_class.call(session: session)

      expect(result[:collector_run]).to be_persisted
      expect(result[:collector_run].status).to eq("completed")
      expect(result[:collector_run].collector_type).to eq("context_intake")
    end

    it "creates knowledge chunks for each response" do
      described_class.call(session: session)

      chunks = KnowledgeChunk.where(project: project)
                             .joins(:knowledge_artifact)
                             .where(knowledge_artifacts: { artifact_type: "business_context" })
      expect(chunks.count).to eq(2)
      expect(chunks.map(&:chunk_type).uniq).to eq([ "context" ])
    end

    it "stales prior business_context artifacts" do
      # Create a prior artifact
      pv = create(:project_version, project: project)
      cr = create(:collector_run, project_version: pv, collector_type: "context_intake")
      prior = create(:knowledge_artifact,
        project: project,
        collector_run: cr,
        artifact_type: "business_context",
        collector_type: "context_intake",
        status: "active")

      described_class.call(session: session)

      expect(prior.reload.status).to eq("stale")
    end

    it "records audit events" do
      expect {
        described_class.call(session: session)
      }.to change(KnowledgeAuditEvent, :count).by_at_least(2)
    end
  end
end
