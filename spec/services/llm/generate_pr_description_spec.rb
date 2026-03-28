# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::GeneratePrDescription do
  let(:agent_summary) { "Added OAuth middleware and user session management." }
  let(:issue_title) { "Add OAuth support" }
  let(:issue_body) { "We need OAuth2 support for third-party integrations." }
  let(:generated_description) do
    <<~DESC
      ## Summary

      Adds OAuth2 middleware to enable third-party integrations, allowing users to authenticate via external providers.

      ## Changes

      - **Auth middleware**: New OAuth2 middleware handling token exchange and session creation
      - **User sessions**: Extended session model to support OAuth-based sessions with configurable TTL
    DESC
  end

  describe ".call" do
    it "returns an LLM-generated PR description" do
      response = instance_double(AgentHarness::Response, success?: true, output: generated_description)
      allow(AgentHarness).to receive(:send_message).and_return(response)

      result = described_class.call(
        agent_summary: agent_summary,
        issue_title: issue_title,
        issue_body: issue_body
      )

      expect(result).to eq(generated_description)
      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Lead with", "Agent Output", agent_summary),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT
      )
    end

    it "includes issue context in the prompt" do
      response = instance_double(AgentHarness::Response, success?: true, output: generated_description)
      allow(AgentHarness).to receive(:send_message).and_return(response)

      described_class.call(
        agent_summary: agent_summary,
        issue_title: issue_title,
        issue_body: issue_body
      )

      expect(AgentHarness).to have_received(:send_message) do |prompt, **_opts|
        expect(prompt).to include(issue_title)
        expect(prompt).to include(issue_body)
      end
    end

    it "handles missing issue context gracefully" do
      response = instance_double(AgentHarness::Response, success?: true, output: generated_description)
      allow(AgentHarness).to receive(:send_message).and_return(response)

      result = described_class.call(agent_summary: agent_summary)

      expect(result).to eq(generated_description)
      expect(AgentHarness).to have_received(:send_message) do |prompt, **_opts|
        expect(prompt).to include("N/A")
      end
    end

    it "returns nil for blank agent_summary" do
      expect(described_class.call(agent_summary: "")).to be_nil
      expect(described_class.call(agent_summary: nil)).to be_nil
    end

    it "returns nil when agent_harness returns a failed response" do
      response = instance_double(AgentHarness::Response, success?: false, output: "")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      result = described_class.call(agent_summary: agent_summary)

      expect(result).to be_nil
    end

    it "returns nil when output is blank" do
      response = instance_double(AgentHarness::Response, success?: true, output: "  \n  ")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      result = described_class.call(agent_summary: agent_summary)

      expect(result).to be_nil
    end

    it "lets AgentHarness errors propagate to the caller for contextual logging" do
      allow(AgentHarness).to receive(:send_message)
        .and_raise(AgentHarness::ProviderError.new("Provider unavailable"))

      expect {
        described_class.call(agent_summary: agent_summary)
      }.to raise_error(AgentHarness::ProviderError)
    end

    it "lets timeout errors propagate to the caller for contextual logging" do
      allow(AgentHarness).to receive(:send_message)
        .and_raise(AgentHarness::TimeoutError.new("Timed out"))

      expect {
        described_class.call(agent_summary: agent_summary)
      }.to raise_error(AgentHarness::TimeoutError)
    end

    it "truncates long agent summaries in the prompt" do
      long_summary = "x" * 30_000
      response = instance_double(AgentHarness::Response, success?: true, output: "Description")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      described_class.call(agent_summary: long_summary)

      expect(AgentHarness).to have_received(:send_message) do |prompt, **_opts|
        expect(prompt).not_to include(long_summary)
      end
    end

    it "truncates long issue bodies in the prompt" do
      long_body = "y" * 10_000
      response = instance_double(AgentHarness::Response, success?: true, output: "Description")
      allow(AgentHarness).to receive(:send_message).and_return(response)

      described_class.call(
        agent_summary: agent_summary,
        issue_body: long_body
      )

      expect(AgentHarness).to have_received(:send_message) do |prompt, **_opts|
        expect(prompt).not_to include(long_body)
      end
    end

    it "lets unexpected (non-AgentHarness) errors propagate to the caller" do
      allow(AgentHarness).to receive(:send_message)
        .and_raise(Encoding::UndefinedConversionError.new("incompatible encoding"))

      expect {
        described_class.call(agent_summary: agent_summary)
      }.to raise_error(Encoding::UndefinedConversionError)
    end

    it "truncates descriptions exceeding MAX_DESCRIPTION_LENGTH" do
      long_description = "A" * 60_000
      response = instance_double(AgentHarness::Response, success?: true, output: long_description)
      allow(AgentHarness).to receive(:send_message).and_return(response)

      result = described_class.call(agent_summary: agent_summary)

      expect(result.length).to be <= described_class::MAX_DESCRIPTION_LENGTH
    end
  end
end
