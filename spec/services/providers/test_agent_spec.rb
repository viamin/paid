# frozen_string_literal: true

require "rails_helper"

RSpec.describe Providers::TestAgent do
  let(:provider) { Struct.new(:provider_key).new("claude") }

  describe ".call" do
    context "when agent responds successfully" do
      let(:response) do
        AgentHarness::Response.new(
          output: "PING OK",
          exit_code: 0,
          duration: 1.2,
          provider: :claude,
          model: "claude-sonnet-4"
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "returns a successful result" do
        result = described_class.call(provider: provider)

        expect(result).to be_success
        expect(result.message).to eq("Agent is healthy")
        expect(result.error_type).to be_nil
      end

      it "sends a test prompt with the correct provider" do
        described_class.call(provider: provider)

        expect(AgentHarness).to have_received(:send_message).with(
          "Respond with exactly: PING OK",
          provider: :claude,
          timeout: 30,
          dangerous_mode: false
        )
      end
    end

    context "when agent responds successfully but output does not match expected ping" do
      let(:response) do
        AgentHarness::Response.new(
          output: "Hello! How can I help you?",
          exit_code: 0,
          duration: 1.0,
          provider: :claude,
          model: "claude-sonnet-4"
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "returns an unexpected error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to include("did not match expected ping")
      end
    end

    context "when agent returns a failure response" do
      let(:response) do
        AgentHarness::Response.new(
          output: "",
          error: "Process exited abnormally",
          exit_code: 1,
          duration: 2.0,
          provider: :claude
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "returns a connection error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:connection)
        expect(result.message).to include("Process exited abnormally")
      end
    end

    context "when authentication fails" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::AuthenticationError, "Invalid API key")
      end

      it "returns an authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Invalid API key")
      end
    end

    context "when the agent times out" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::TimeoutError, "Timed out after 30s")
      end

      it "returns a timeout error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:timeout)
        expect(result.message).to eq("Timed out after 30s")
      end
    end

    context "when a generic agent harness error occurs" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::Error, "Connection refused")
      end

      it "returns a connection error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:connection)
        expect(result.message).to eq("Connection refused")
      end
    end

    context "when the provider is unsupported" do
      before do
        allow(ProviderSupport).to receive(:supported_provider_key?).and_return(false)
      end

      it "returns an unexpected error indicating the provider is unrecognized" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to include("not recognized by the agent harness")
      end
    end

    context "when the provider is supported but not container-executable" do
      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: false)
      end

      it "returns an installation error indicating the CLI is not installed" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:installation)
        expect(result.message).to include("CLI is not installed in the agent container")
      end
    end

    context "when an unexpected error occurs" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(RuntimeError, "Something went wrong")
      end

      it "returns an unexpected error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Something went wrong")
      end
    end
  end
end
