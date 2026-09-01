# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-001
# @spec SESSION-SUMMARY-002
# @spec SESSION-SUMMARY-003
RSpec.describe Knowledge::SessionSummaries::Capture do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:response) do
    instance_double(
      AgentHarness::Response,
      tokens: 24,
      input_tokens: 10,
      output_tokens: 14,
      model: "claude-sonnet-4-5"
    )
  end
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
      response: response
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

    it "repairs an existing summary that is missing its knowledge artifact" do
      summary = create(:agent_run_session_summary, project: project, agent_run: agent_run, issue: issue)
      create_session_summary_bookkeeping!(summary)

      expect(Llm::GenerateSessionSummary).not_to receive(:call)

      expect {
        result = described_class.call(agent_run: agent_run)
        expect(result).to eq(summary)
      }.to change { KnowledgeArtifact.active.where(artifact_type: "session_summary").count }.by(1)
    end

    it "repairs an existing summary that is missing its output metric" do
      summary = create(:agent_run_session_summary, project: project, agent_run: agent_run, issue: issue)
      create_session_summary_token_usage!(summary)
      Knowledge::SessionSummaries::SyncKnowledgeArtifact.call(session_summary: summary)

      expect(Llm::GenerateSessionSummary).not_to receive(:call)

      expect {
        result = described_class.call(agent_run: agent_run)
        expect(result).to eq(summary)
      }.to change { session_summary_metric_for(summary).present? }.from(false).to(true)
    end

    it "rolls back the summary when artifact sync fails so a retry can recreate it cleanly" do
      allow(Knowledge::SessionSummaries::SyncKnowledgeArtifact).to receive(:call).and_raise(StandardError, "boom")

      expect {
        described_class.call(agent_run: agent_run)
      }.to raise_error(StandardError, "boom")

      expect(AgentRunSessionSummary.find_by(agent_run: agent_run)).to be_nil
      expect(session_summary_token_usages).to be_empty
      expect(LlmOutputMetric.where(source_type: "AgentRunSessionSummary").count).to eq(0)
      expect(KnowledgeArtifact.active.where(artifact_type: "session_summary")).to be_empty

      allow(Knowledge::SessionSummaries::SyncKnowledgeArtifact).to receive(:call).and_call_original

      expect {
        result = described_class.call(agent_run: agent_run)
        expect(result).to be_present
      }.to change(AgentRunSessionSummary, :count).by(1)
        .and change(session_summary_token_usages, :count).by(1)
        .and change(LlmOutputMetric, :count).by(1)
        .and change { KnowledgeArtifact.active.where(artifact_type: "session_summary").count }.by(1)
    end

    it "rolls back the summary when token tracking fails so a retry can recreate it cleanly" do
      allow(TokenUsageTracker).to receive(:track).and_raise(StandardError, "boom")

      expect {
        described_class.call(agent_run: agent_run)
      }.to raise_error(StandardError, "boom")

      expect(AgentRunSessionSummary.find_by(agent_run: agent_run)).to be_nil
      expect(session_summary_token_usages).to be_empty
      expect(LlmOutputMetric.where(source_type: "AgentRunSessionSummary").count).to eq(0)
      expect(KnowledgeArtifact.active.where(artifact_type: "session_summary")).to be_empty

      allow(TokenUsageTracker).to receive(:track).and_call_original

      expect {
        result = described_class.call(agent_run: agent_run)
        expect(result).to be_present
      }.to change(AgentRunSessionSummary, :count).by(1)
        .and change(session_summary_token_usages, :count).by(1)
        .and change(LlmOutputMetric, :count).by(1)
        .and change { KnowledgeArtifact.active.where(artifact_type: "session_summary").count }.by(1)
    end

    it "repairs the knowledge artifact when a concurrent capture wins the insert race" do
      existing = create(:agent_run_session_summary, project: project, agent_run: agent_run, issue: issue)
      create_session_summary_bookkeeping!(existing)
      find_by_calls = 0
      allow(AgentRunSessionSummary).to receive(:find_by).and_wrap_original do |original, *args|
        find_by_calls += 1
        find_by_calls == 1 ? nil : existing
      end
      allow(AgentRunSessionSummary).to receive(:create!).and_raise(
        ActiveRecord::RecordNotUnique.new("agent_run_id duplicate")
      )

      expect {
        result = described_class.call(agent_run: agent_run)
        expect(result).to eq(existing)
      }.to change { KnowledgeArtifact.active.where(artifact_type: "session_summary").count }.by(1)
    end
  end

  def session_summary_metric_for(summary)
    LlmOutputMetric.find_by(
      project: project,
      output_type: "session_summary",
      source_type: "AgentRunSessionSummary",
      source_id: summary.id
    )
  end

  def session_summary_token_usages
    agent_run.token_usages.where("metadata ->> 'operation' = ?", "session_summary")
  end

  def create_session_summary_bookkeeping!(summary)
    create_session_summary_token_usage!(summary)

    LlmOutputMetrics::Record.call(
      project: project,
      output_type: "session_summary",
      prompt_slug: Llm::GenerateSessionSummary::PROMPT_SLUG,
      prompt_project: project,
      source_type: "AgentRunSessionSummary",
      source_id: summary.id
    )
  end

  def create_session_summary_token_usage!(_summary)
    TokenUsageTracker.track(
      tracked_run: agent_run,
      usage: {
        tokens_input: response.input_tokens,
        tokens_output: response.output_tokens,
        llm_model: response.model,
        request_type: "agent",
        metadata: { operation: "session_summary" }
      },
      enforce_guardrails: false
    )
  end
end
