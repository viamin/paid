# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ThinkingEffort do
  let!(:reasoning_model) do
    create(:llm_model,
      model_id: "gpt-reasoning-test",
      metadata: { "supports_reasoning" => true, "reasoning_effort_values" => %w[low high] })
  end

  # @spec CHAT-THINKING-EFFORT-001
  it "fails closed when the active chat transport cannot configure reasoning" do
    allow(ChatSessions::BuildLlmClient::HttpClient).to receive(:reasoning_effort_transport_supported?).and_return(false)

    expect(described_class.allowed_values(reasoning_model.model_id)).to eq([])
    expect(described_class.resolve!(model_id: reasoning_model.model_id, value: "")).to be_nil
    expect { described_class.resolve!(model_id: reasoning_model.model_id, value: "high") }
      .to raise_error(ArgumentError, /not a supported thinking effort/)
  end

  # @spec CHAT-THINKING-EFFORT-001 CHAT-THINKING-EFFORT-006
  it "uses only capability-declared values once the transport supports them" do
    allow(ChatSessions::BuildLlmClient::HttpClient).to receive(:reasoning_effort_transport_supported?).and_return(true)

    expect(described_class.options_for(reasoning_model.model_id).map(&:value)).to eq(%w[low high])
    expect(described_class.resolve!(model_id: reasoning_model.model_id, value: "high")).to eq("high")
    expect { described_class.resolve!(model_id: reasoning_model.model_id, value: "medium") }
      .to raise_error(ArgumentError, /not a supported thinking effort/)
  end
end
