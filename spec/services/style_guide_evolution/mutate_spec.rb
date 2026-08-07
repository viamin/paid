# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuideEvolution::Mutate do
  let(:style_guide) { create(:style_guide, :global, raw_content: source_content) }
  let(:source_content) { "# Style Guide\n\nUse descriptive names." }
  let(:response_body) do
    JSON.generate(
      "mutations" => [
        {
          "raw_content" => "Updated guide content",
          "strategy" => "refinement",
          "reasoning" => "Clarified naming rules",
          "expected_improvement" => "More consistent output"
        }
      ]
    )
  end
  let(:response) { instance_double(AgentHarness::Response, success?: true, output: response_body) }

  before do
    allow(AgentHarness).to receive(:send_message).and_return(response)
    allow(Llm::TextMode).to receive(:options).and_return({})
  end

  it "returns mutations from the LLM response" do
    mutations = described_class.call(style_guide: style_guide)

    expect(mutations.size).to eq(1)
    expect(mutations.first).to have_attributes(
      raw_content: "Updated guide content",
      strategy: "refinement",
      reasoning: "Clarified naming rules",
      expected_improvement: "More consistent output"
    )
  end

  # @spec STYLE-GUIDE-EVOLUTION-007
  it "redacts the style guide content before sending it to the LLM" do
    sent_prompt = nil
    allow(Knowledge::Redaction::Redactor).to receive(:call)
      .with(text: source_content)
      .and_return(double(clean_text: "[REDACTED]"))
    allow(AgentHarness).to receive(:send_message) do |prompt, **options|
      sent_prompt = prompt
      expect(options).to include(provider: :claude, model: "claude-sonnet-4-6", timeout: 60, tools: :none)
      response
    end

    described_class.call(style_guide: style_guide)

    expect(sent_prompt).to include("[REDACTED]")
    expect(sent_prompt).not_to include(source_content)
  end

  # @spec STYLE-GUIDE-EVOLUTION-007
  it "drops oversized generated mutations" do
    oversized = "x" * (described_class::MAX_GENERATED_TEMPLATE_LENGTH + 1)
    allow(response).to receive(:output).and_return(
      JSON.generate(
        "mutations" => [
          { "raw_content" => oversized, "strategy" => "refinement" }
        ]
      )
    )

    expect(described_class.call(style_guide: style_guide)).to eq([])
  end
end
