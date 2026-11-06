# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::PartialCloseoutFailure do # @spec PARTIAL-CLOSEOUT-042
  describe ".category_for" do
    it "keeps the bounded category the analyzer recorded" do
      failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("boom", category: "timeout")

      expect(described_class.category_for(failure)).to eq("timeout")
    end

    it "classifies a runner timeout separately from a generic transport error" do
      expect(described_class.category_for(AgentHarness::TimeoutError.new("timed out")))
        .to eq(described_class::TIMEOUT)
      expect(described_class.category_for(AgentHarness::Error.new("boom")))
        .to eq(described_class::TRANSPORT_ERROR)
    end

    it "classifies configuration and authentication failures as operator work" do
      expect(described_class.category_for(AgentHarness::ConfigurationError.new("no runner")))
        .to eq(described_class::CONFIGURATION_ERROR)
      expect(described_class.category_for(AgentHarness::AuthenticationError.new("logged out")))
        .to eq(described_class::AUTHENTICATION_UNAVAILABLE)
    end
  end

  describe ".retryable?" do
    it "retries transient transport failures" do
      expect(described_class.retryable?(described_class::TIMEOUT)).to be true
      expect(described_class.retryable?(described_class::TRANSPORT_ERROR)).to be true
      expect(described_class.retryable?(described_class::UNSUCCESSFUL_RESPONSE)).to be true
    end

    it "does not retry failures an operator has to resolve first" do
      expect(described_class.retryable?(described_class::AUTHENTICATION_UNAVAILABLE)).to be false
      expect(described_class.retryable?(described_class::CONFIGURATION_ERROR)).to be false
    end
  end

  describe ".next_action_for" do
    it "names the exact operator action for credential and configuration failures" do
      expect(described_class.next_action_for(described_class::AUTHENTICATION_UNAVAILABLE))
        .to eq("reconnect_runner_credential_then_retry")
      expect(described_class.next_action_for(described_class::CONFIGURATION_ERROR))
        .to eq("fix_runner_configuration_then_retry")
    end

    it "schedules an automatic retry for transient failures" do
      expect(described_class.next_action_for(described_class::TIMEOUT)).to eq(described_class::RECOVERY_ACTION)
    end
  end
end
