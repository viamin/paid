# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuideCompressionJob do
  let(:style_guide) { create(:style_guide, :global, raw_content: "# Ruby Style Guide\n\n- Use snake_case") }

  describe "#perform" do
    context "when compression succeeds" do
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

      it "compresses the style guide and persists the result" do
        described_class.new.perform(style_guide.id)

        style_guide.reload
        expect(style_guide.compressed_content).to eq("- snake_case for methods")
        expect(style_guide.compression_metadata).to include(
          "model" => "claude-sonnet-4-6",
          "raw_length" => style_guide.raw_content.bytesize
        )
      end
    end

    context "when AgentHarness raises an error" do
      before do
        allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "LLM unavailable")
      end

      it "logs the error and does not raise" do
        expect(Rails.logger).to receive(:error).with(hash_including(
          message: "style_guides.compression_failed",
          error_class: "AgentHarness::Error"
        ))

        expect { described_class.new.perform(style_guide.id) }.not_to raise_error
      end
    end

    context "when the LLM returns empty output" do
      let(:response) do
        AgentHarness::Response.new(
          output: "",
          exit_code: 0,
          duration: 1.0,
          provider: :claude,
          model: "claude-sonnet-4-6",
          tokens: { input: 500, output: 0, total: 500 }
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "logs the compression error and does not raise" do
        expect(Rails.logger).to receive(:error).with(hash_including(
          message: "style_guides.compression_failed",
          error_class: "StyleGuides::CompressionError"
        ))

        expect { described_class.new.perform(style_guide.id) }.not_to raise_error
      end
    end
  end
end
