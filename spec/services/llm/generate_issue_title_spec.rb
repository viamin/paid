# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::GenerateIssueTitle do
  let(:summary) { "The authentication system uses JWT tokens with a 24-hour expiry." }

  describe ".call" do
    it "returns a title generated via agent_harness" do
      response = instance_double(AgentHarness::Response, success?: true, output: "JWT authentication system review")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to eq("JWT authentication system review")
      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Generate a concise GitHub issue title/),
        provider: :claude,
        timeout: described_class::TIMEOUT
      )
    end

    it "strips quotes from the generated title" do
      response = instance_double(AgentHarness::Response, success?: true, output: '"JWT authentication system review"')
      allow(AgentHarness).to receive(:send_message).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to eq("JWT authentication system review")
    end

    it "truncates titles longer than MAX_TITLE_LENGTH" do
      long_title = "A" * 300
      response = instance_double(AgentHarness::Response, success?: true, output: long_title)
      allow(AgentHarness).to receive(:send_message).and_return(response)

      title = described_class.call(summary: summary)

      expect(title.length).to be <= described_class::MAX_TITLE_LENGTH
    end

    it "returns nil for blank summary" do
      expect(described_class.call(summary: "")).to be_nil
      expect(described_class.call(summary: nil)).to be_nil
    end

    it "returns nil when agent_harness returns a failed response" do
      response = instance_double(AgentHarness::Response, success?: false, output: "")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end

    it "returns nil on agent_harness error and logs warning" do
      allow(AgentHarness).to receive(:send_message)
        .and_raise(AgentHarness::ProviderError.new("Provider unavailable"))

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "agent_execution.llm_generate_issue_title_failed"
      ))

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end

    it "returns nil on timeout and logs warning" do
      allow(AgentHarness).to receive(:send_message)
        .and_raise(AgentHarness::TimeoutError.new("Timed out"))

      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "agent_execution.llm_generate_issue_title_failed"
      ))

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end

    it "truncates long summaries in the prompt" do
      long_summary = "x" * 10_000
      response = instance_double(AgentHarness::Response, success?: true, output: "Test title")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      described_class.call(summary: long_summary)

      expect(AgentHarness).to have_received(:send_message) do |prompt, **_opts|
        expect(prompt.length).to be <= described_class::MAX_SUMMARY_INPUT + 200
      end
    end

    it "returns nil when output is blank" do
      response = instance_double(AgentHarness::Response, success?: true, output: "  \n  ")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end
  end
end
