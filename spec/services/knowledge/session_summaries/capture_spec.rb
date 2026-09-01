# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-001
# @spec SESSION-SUMMARY-002
# @spec SESSION-SUMMARY-003
RSpec.describe Knowledge::SessionSummaries::Capture do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) do
    create(:agent_run, :completed, project: project, issue: issue,
      pull_request_number: 7, pull_request_url: "https://github.com/example/repo/pull/7")
  end

  let(:generated) do
    Llm::GenerateSessionSummary::Result.new(
      summary: "Implemented rate limiting and added tests.",
      files_touched: [ "app/services/rate_limiter.rb" ],
      decisions: [ "Used a sliding window." ],
      assumptions: [ "Assumed Redis is available." ],
      failures: [],
      follow_ups: [ "Add a dashboard panel." ],
      learnings: [ "Config lives in config/rate_limits.yml." ],
      response: nil
    )
  end

  before do
    allow(Llm::GenerateSessionSummary).to receive(:call).and_return(generated)
  end

  describe ".call" do
    it "creates an observation-status session summary with the synthesized fields" do
      summary = described_class.call(agent_run: agent_run)

      expect(summary).to be_a(AgentRunSessionSummary)
      expect(summary).to be_persisted
      expect(summary.status).to eq("observation")
      expect(summary.summary).to eq("Implemented rate limiting and added tests.")
      expect(summary.files_touched).to eq([ "app/services/rate_limiter.rb" ])
      expect(summary.learnings).to eq([ "Config lives in config/rate_limits.yml." ])
    end

    it "links the summary to the project, agent run, and issue" do
      summary = described_class.call(agent_run: agent_run)

      expect(summary.project).to eq(project)
      expect(summary.agent_run).to eq(agent_run)
      expect(summary.issue).to eq(issue)
      expect(summary.pull_request_number).to eq(7)
      expect(summary.pull_request_url).to eq("https://github.com/example/repo/pull/7")
    end

    it "syncs the summary into the knowledge-artifact pipeline" do
      expect {
        described_class.call(agent_run: agent_run)
      }.to change { KnowledgeArtifact.active.where(artifact_type: "session_summary").count }.by(1)
    end

    it "records an LlmOutputMetric for the drafted summary" do
      summary = described_class.call(agent_run: agent_run)

      metric = LlmOutputMetric.find_by(source_type: "AgentRunSessionSummary", source_id: summary.id)
      expect(metric).to be_present
      expect(metric.output_type).to eq("session_summary")
    end

    it "returns nil and creates nothing when the LLM produces no result" do
      allow(Llm::GenerateSessionSummary).to receive(:call).and_return(nil)

      expect {
        result = described_class.call(agent_run: agent_run)
        expect(result).to be_nil
      }.not_to change(AgentRunSessionSummary, :count)
    end

    it "is idempotent: a second call returns the existing summary without regenerating" do
      first = described_class.call(agent_run: agent_run)

      expect(Llm::GenerateSessionSummary).not_to receive(:call)
      second = described_class.call(agent_run: agent_run)

      expect(second).to eq(first)
    end
  end
end
