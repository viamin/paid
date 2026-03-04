# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuideCompressionJob do
  let(:style_guide) { create(:style_guide, :global, raw_content: "# Ruby Style Guide\n\n- Use snake_case") }

  describe "#perform" do
    let(:response) do
      AgentHarness::Response.new(
        output: "- snake_case for methods",
        exit_code: 0,
        duration: 2.5,
        provider: :claude,
        model: "claude-sonnet-4-6",
        tokens: { input: 500, output: 100, total: 600 }
      )
    end

    before do
      allow(AgentHarness).to receive(:send_message).and_return(response)
    end

    it "calls StyleGuides::Compress with the style guide" do
      allow(StyleGuides::Compress).to receive(:call)

      described_class.new.perform(style_guide.id)

      expect(StyleGuides::Compress).to have_received(:call).with(style_guide: style_guide)
    end

    it "logs and does not raise on AgentHarness::Error" do
      allow(StyleGuides::Compress).to receive(:call).and_raise(AgentHarness::Error, "LLM unavailable")

      expect(Rails.logger).to receive(:error).with(hash_including(
        message: "style_guides.compression_failed",
        error_class: "AgentHarness::Error"
      ))

      expect { described_class.new.perform(style_guide.id) }.not_to raise_error
    end

    it "logs and does not raise on CompressionError" do
      allow(StyleGuides::Compress).to receive(:call).and_raise(StyleGuides::CompressionError, "Empty output")

      expect(Rails.logger).to receive(:error).with(hash_including(
        message: "style_guides.compression_failed",
        error_class: "StyleGuides::CompressionError"
      ))

      expect { described_class.new.perform(style_guide.id) }.not_to raise_error
    end
  end
end
