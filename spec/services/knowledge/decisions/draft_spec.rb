# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Decisions::Draft do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) do
    create(:agent_run, :completed, project: project, issue: issue,
      base_commit_sha: "aaa0000000000000000000000000000000000000",
      result_commit_sha: "bbb0000000000000000000000000000000000000")
  end

  let(:llm_json) do
    {
      title: "Use JWT for auth",
      summary: "Decided to use JWT.",
      context: "Session auth was insufficient.",
      decision: "Implement JWT auth.",
      consequences: "Clients must refresh tokens.",
      tags: %w[auth api]
    }.to_json
  end

  let(:llm_response) do
    response = Object.new
    json = llm_json
    response.define_singleton_method(:output) { json }
    response.define_singleton_method(:success?) { true }
    response
  end

  before do
    allow(AgentHarness).to receive(:send_message).and_return(llm_response)
    agent_run.log!("stdout", "Implemented JWT authentication for API endpoints")
  end

  describe ".call" do
    it "creates a persisted active decision record" do
      record = described_class.call(agent_run: agent_run)

      expect(record).to be_a(DecisionRecord)
      expect(record).to be_persisted
      expect(record.status).to eq("active")
    end

    it "populates record fields from LLM response" do
      record = described_class.call(agent_run: agent_run)

      expect(record.title).to eq("Use JWT for auth")
      expect(record.summary).to eq("Decided to use JWT.")
      expect(record.decision).to eq("Implement JWT auth.")
      expect(record.tags).to eq(%w[auth api])
    end

    it "links record to project, agent run, and issue" do
      record = described_class.call(agent_run: agent_run)

      expect(record.project).to eq(project)
      expect(record.agent_run).to eq(agent_run)
      expect(record.issue).to eq(issue)
    end

    it "stores commit SHA range from agent run" do
      record = described_class.call(agent_run: agent_run)

      expect(record.commit_sha_start).to eq("aaa0000000000000000000000000000000000000")
      expect(record.commit_sha_end).to eq("bbb0000000000000000000000000000000000000")
    end

    it "creates links to agent run and issue" do
      record = described_class.call(agent_run: agent_run)

      links = record.decision_record_links
      expect(links.count).to eq(2)
      expect(links.find_by(linkable_type: "AgentRun").linkable_id).to eq(agent_run.id.to_s)
      expect(links.find_by(linkable_type: "Issue").linkable_id).to eq(issue.id.to_s)
    end

    it "returns nil when agent has no output" do
      agent_run.agent_run_logs.destroy_all
      result = described_class.call(agent_run: agent_run)
      expect(result).to be_nil
    end

    it "returns nil when LLM returns unparseable response" do
      allow(llm_response).to receive(:output).and_return("not json")
      result = described_class.call(agent_run: agent_run)
      expect(result).to be_nil
    end

    it "calls AgentHarness with correct parameters" do
      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Decision Record/),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT,
        dangerous_mode: false
      )
    end
  end
end
