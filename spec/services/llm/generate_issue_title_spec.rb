# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::GenerateIssueTitle do
  before { configure_llm_routing()
  }

  after { Current.user = nil }


  let(:summary) { "The authentication system uses JWT tokens with a 24-hour expiry." }

  describe ".call" do
    it "returns a title generated via agent_harness" do
      response = instance_double(AgentHarness::Response, success?: true, output: "JWT authentication system review")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to eq("JWT authentication system review")
      expect(AgentHarness.conductor).to have_received(:execute_direct).with(
        a_string_matching(/Generate a concise GitHub issue title/), hash_including(provider: :claude,
        model: "configured-mid",
        timeout: described_class::TIMEOUT,
        tools: :none,
        dangerous_mode: false, mcp_servers: [], provider_runtime: an_instance_of(AgentHarness::ProviderRuntime)))
    end


    it "preserves the configured subscription billing mode" do
      response = instance_double(AgentHarness::Response, success?: true, output: "JWT authentication system review")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      described_class.call(summary: summary)

      expect(AgentHarness.conductor).to have_received(:execute_direct) do |_prompt, **opts|
        expect(opts).not_to have_key(:mode)
      end
    end

    it "passes tools: :none to disable CLI tool access during text-only generation" do
      response = instance_double(AgentHarness::Response, success?: true, output: "JWT authentication system review")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      described_class.call(summary: summary)

      expect(AgentHarness.conductor).to have_received(:execute_direct)
        .with(anything, hash_including(tools: :none))
    end

    it "strips double quotes from the generated title" do
      response = instance_double(AgentHarness::Response, success?: true, output: '"JWT authentication system review"')
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to eq("JWT authentication system review")
    end

    it "strips single quotes from the generated title" do
      response = instance_double(AgentHarness::Response, success?: true, output: "'JWT authentication system review'")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to eq("JWT authentication system review")
    end

    it "strips backticks from the generated title" do
      response = instance_double(AgentHarness::Response, success?: true, output: "`JWT authentication system review`")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to eq("JWT authentication system review")
    end

    it "strips curly quotes from the generated title" do
      response = instance_double(AgentHarness::Response, success?: true, output: "\u201CJWT authentication system review\u201D")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to eq("JWT authentication system review")
    end

    it "truncates titles longer than MAX_TITLE_LENGTH" do
      long_title = "A" * 300
      response = instance_double(AgentHarness::Response, success?: true, output: long_title)
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title.length).to be <= described_class::MAX_TITLE_LENGTH
    end

    it "returns nil for blank summary" do
      expect(described_class.call(summary: "")).to be_nil
      expect(described_class.call(summary: nil)).to be_nil
    end

    it "returns nil when agent_harness returns a failed response" do
      response = instance_double(AgentHarness::Response, success?: false, output: "")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end

    it "returns nil on agent_harness error and logs warning" do
      allow(AgentHarness.conductor).to receive(:execute_direct)
        .and_raise(AgentHarness::ProviderError.new("Provider unavailable"))

      allow(Rails.logger).to receive(:warn).and_call_original
      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "agent_execution.llm_generate_issue_title_failed"
      ))

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end

    it "returns nil on timeout and logs warning" do
      allow(AgentHarness.conductor).to receive(:execute_direct)
        .and_raise(AgentHarness::TimeoutError.new("Timed out"))

      allow(Rails.logger).to receive(:warn).and_call_original
      expect(Rails.logger).to receive(:warn).with(hash_including(
        message: "agent_execution.llm_generate_issue_title_failed"
      ))

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end

    it "truncates long summaries in the prompt" do
      long_summary = "x" * 10_000
      response = instance_double(AgentHarness::Response, success?: true, output: "Test title")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      described_class.call(summary: long_summary)

      expect(AgentHarness.conductor).to have_received(:execute_direct) do |prompt, **_opts|
        expect(prompt.length).to be <= described_class::MAX_SUMMARY_INPUT + 200
      end
    end

    it "returns nil when output is blank" do
      response = instance_double(AgentHarness::Response, success?: true, output: "  \n  ")
      allow(AgentHarness.conductor).to receive(:execute_direct).and_return(response)

      title = described_class.call(summary: summary)

      expect(title).to be_nil
    end
  end
end
