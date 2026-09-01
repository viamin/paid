# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-002
RSpec.describe Llm::GenerateSessionSummary do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :completed, project: project, issue: issue) }

  let(:llm_json) do
    {
      summary: "Implemented rate limiting and added tests.",
      files_touched: %w[app/services/rate_limiter.rb spec/services/rate_limiter_spec.rb],
      decisions: [ "Used a sliding window instead of a token bucket." ],
      assumptions: [ "Assumed Redis is available." ],
      failures: [ "First attempt with an in-memory counter failed under concurrent requests." ],
      follow_ups: [ "Add a dashboard panel for rejections." ],
      learnings: [ "Rate limit config lives in config/rate_limits.yml." ]
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
    allow(Llm::TextMode).to receive(:options).and_return({})
    agent_run.log!("stdout", "Implemented rate limiting for the public API.")
  end

  describe ".call" do
    it "returns nil when the agent run has no transcript" do
      empty_agent_run = create(:agent_run, :completed, project: project, issue: issue)

      expect(described_class.call(agent_run: empty_agent_run)).to be_nil
      expect(AgentHarness).not_to have_received(:send_message)
    end

    it "returns a populated result from the parsed LLM response" do
      result = described_class.call(agent_run: agent_run)

      expect(result.summary).to eq("Implemented rate limiting and added tests.")
      expect(result.files_touched).to eq(%w[app/services/rate_limiter.rb spec/services/rate_limiter_spec.rb])
      expect(result.decisions).to eq([ "Used a sliding window instead of a token bucket." ])
      expect(result.assumptions).to eq([ "Assumed Redis is available." ])
      expect(result.failures).to eq([ "First attempt with an in-memory counter failed under concurrent requests." ])
      expect(result.follow_ups).to eq([ "Add a dashboard panel for rejections." ])
      expect(result.learnings).to eq([ "Rate limit config lives in config/rate_limits.yml." ])
      expect(result.response).to eq(llm_response)
    end

    it "returns nil when the provider call is unsuccessful" do
      allow(llm_response).to receive(:success?).and_return(false)

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "returns nil when the response is not valid JSON" do
      allow(llm_response).to receive(:output).and_return("not json")

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "returns nil when the parsed JSON has no summary" do
      allow(llm_response).to receive(:output).and_return({ decisions: [ "x" ] }.to_json)

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "strips a surrounding markdown fence before parsing" do
      allow(llm_response).to receive(:output).and_return("```json\n#{llm_json}\n```")

      result = described_class.call(agent_run: agent_run)

      expect(result.summary).to eq("Implemented rate limiting and added tests.")
    end
  end

  describe "secret redaction" do
    it "redacts secrets in the transcript before sending it to the LLM" do
      leaky_agent_run = create(:agent_run, :completed, project: project, issue: issue)
      leaky_agent_run.log!("stdout", "Pushed with TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 to origin.")

      described_class.call(agent_run: leaky_agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[REDACTED]").and(
          satisfy { |s| !s.include?("ghp_abcdefghijklmnopqrstuvwxyz0123456789") }
        ),
        hash_including(provider: :claude)
      )
    end

    it "redacts secrets in the issue title before sending it to the LLM" do
      leaky_issue = create(:issue, project: project, title: "Rotate TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789")
      leaky_agent_run = create(:agent_run, :completed, project: project, issue: leaky_issue)
      leaky_agent_run.log!("stdout", "Some work happened.")

      described_class.call(agent_run: leaky_agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[REDACTED]").and(
          satisfy { |s| !s.include?("ghp_abcdefghijklmnopqrstuvwxyz0123456789") }
        ),
        hash_including(provider: :claude)
      )
    end

    it "redacts secrets in the error message before sending it to the LLM" do
      leaky_agent_run = create(:agent_run, :completed, project: project, issue: issue,
        error_message: "Failed: TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 unreachable")
      leaky_agent_run.log!("stdout", "Some work happened.")

      described_class.call(agent_run: leaky_agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[REDACTED]").and(
          satisfy { |s| !s.include?("ghp_abcdefghijklmnopqrstuvwxyz0123456789") }
        ),
        hash_including(provider: :claude)
      )
    end

    it "redacts secrets echoed back by the LLM into the parsed result" do
      leaky_json = {
        summary: "Committed a fix using TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789.",
        files_touched: [], decisions: [], assumptions: [], failures: [], follow_ups: [], learnings: []
      }.to_json
      allow(llm_response).to receive(:output).and_return(leaky_json)

      result = described_class.call(agent_run: agent_run)

      expect(result.summary).to include("[REDACTED]")
      expect(result.summary).not_to include("ghp_abcdefghijklmnopqrstuvwxyz0123456789")
    end
  end
end
