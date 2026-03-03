# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuides::Compress do
  let(:style_guide) { create(:style_guide, :global, raw_content: "# Ruby Style Guide\n\n" + (1..50).map { |i| "- Rule #{i}\n" }.join) }

  describe ".call" do
    let(:response) do
      AgentHarness::Response.new(
        output: "- snake_case for methods\n- CamelCase for classes",
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

    it "compresses the style guide content" do
      described_class.call(style_guide: style_guide)

      style_guide.reload
      expect(style_guide.compressed_content).to eq("- snake_case for methods\n- CamelCase for classes")
    end

    it "stores compression metadata" do
      described_class.call(style_guide: style_guide)

      style_guide.reload
      expect(style_guide.compression_metadata).to include(
        "compressed_at" => be_present,
        "raw_length" => style_guide.raw_content.length,
        "compressed_length" => 48,
        "compression_ratio" => be_a(Float)
      )
    end

    it "calls AgentHarness with the compression prompt" do
      described_class.call(style_guide: style_guide)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Compress the following coding style guide"),
        provider: :claude,
        model: "claude-sonnet-4-6",
        dangerous_mode: false
      )
    end

    it "returns the updated style guide" do
      result = described_class.call(style_guide: style_guide)

      expect(result).to eq(style_guide)
      expect(result.compressed?).to be true
    end
  end
end
