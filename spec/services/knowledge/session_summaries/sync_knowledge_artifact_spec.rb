# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-003
RSpec.describe Knowledge::SessionSummaries::SyncKnowledgeArtifact do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }
  let(:session_summary) { create(:agent_run_session_summary, project: project, agent_run: agent_run) }

  describe ".call" do
    it "creates an active knowledge artifact for the session summary" do
      expect {
        described_class.call(session_summary: session_summary)
      }.to change(KnowledgeArtifact, :count).by(1)

      artifact = KnowledgeArtifact.active.find_by(artifact_type: "session_summary")
      expect(artifact.scope_path).to eq("agent_runs/#{agent_run.id}/session_summary")
      expect(artifact.project).to eq(project)
    end

    it "completes the synthetic collector run" do
      described_class.call(session_summary: session_summary)

      collector_run = CollectorRun.find_by(collector_type: "session_summary")
      expect(collector_run.status).to eq("completed")
    end

    it "reuses the same synthetic project version and collector run across summaries" do
      other_agent_run = create(:agent_run, :completed, project: project)
      other_summary = create(:agent_run_session_summary, project: project, agent_run: other_agent_run)

      described_class.call(session_summary: session_summary)
      described_class.call(session_summary: other_summary)

      expect(ProjectVersion.where(project: project, branch: "session-summaries").count).to eq(1)
      expect(CollectorRun.where(collector_type: "session_summary").count).to eq(1)
      expect(KnowledgeArtifact.active.where(artifact_type: "session_summary").count).to eq(2)
    end

    it "marks the collector run failed and re-raises when storage fails" do
      allow(Knowledge::ArtifactStore).to receive(:new).and_raise(StandardError, "boom")

      expect {
        described_class.call(session_summary: session_summary)
      }.to raise_error(StandardError, "boom")

      collector_run = CollectorRun.find_by(collector_type: "session_summary")
      expect(collector_run.status).to eq("failed")
    end
  end
end
