# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::ApiRequest do
  let(:owner) { create(:user) }
  let(:key) { create(:runner_api_key, user: owner, api_service_type: "openai") }
  let(:runner) { create(:runner, :api_key, user: owner, runner_key: "codex", provider_api_key: key) }
  let(:runtime) { AgentHarness::ProviderRuntime.new(model: "chosen-model") }
  let(:transport) { instance_double(AgentHarness::Api::ChatTransport) }

  before do
    allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(transport)
  end

  # @spec LLM-ROUTING-003 LLM-ROUTING-005
  it "uses the selected API credential without running a CLI" do
    allow(transport).to receive(:call).and_return(status: :succeeded, content: "assessment", model: "reported-model",
      usage: { input_tokens: 10, output_tokens: 4 })

    result = described_class.call(runner: runner, runtime: runtime, prompt: "Assess", timeout: 30)

    expect(result).to be_success
    expect(result).to have_attributes(output: "assessment", model: "reported-model", input_tokens: 10, output_tokens: 4)
    expect(transport).to have_received(:call) do |request|
      expect(request[:tools]).to eq([])
      expect(request[:candidates]).to contain_exactly(include(provider: :openai, protocol: :responses,
        model: "chosen-model", credentials: { api_key: key.api_key }))
    end
  end

  # @spec LLM-ROUTING-005
  it "keeps failed or partial API output unsuccessful without exposing the provider's error payload" do
    allow(transport).to receive(:call).and_return(status: :partial, content: "incomplete", error: { message: "private payload" })

    result = described_class.call(runner: runner, runtime: runtime, prompt: "Assess", timeout: 30)

    expect(result).not_to be_success
    expect(result.error).to eq("Configured API text request failed")
  end

  # @spec LLM-ROUTING-003
  it "preserves authentication failures without including the provider payload" do
    allow(transport).to receive(:call).and_return(status: :failed, error: { category: :authentication, message: "private payload" })

    expect { described_class.call(runner: runner, runtime: runtime, prompt: "Assess", timeout: 30) }
      .to raise_error(AgentHarness::AuthenticationError, "Configured API text request failed")
  end
end
