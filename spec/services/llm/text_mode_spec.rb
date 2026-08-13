# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::TextMode do
  describe ".options" do
    context "when ANTHROPIC_API_KEY is set" do
      before { stub_const("ENV", ENV.to_hash.merge("ANTHROPIC_API_KEY" => "sk-ant-abc", "PAID_LLM_TEXT_MODE_DISABLED" => nil)) }

      it "returns the text-mode option" do
        expect(described_class.options).to eq(mode: :text)
      end
    end

    context "when ANTHROPIC_API_KEY is blank" do
      before { stub_const("ENV", ENV.to_hash.merge("ANTHROPIC_API_KEY" => "", "PAID_LLM_TEXT_MODE_DISABLED" => nil)) }

      it "returns an empty hash so the call falls back to CLI transport" do
        expect(described_class.options).to eq({})
      end
    end

    context "when ANTHROPIC_API_KEY is missing" do
      before { stub_const("ENV", ENV.to_hash.except("ANTHROPIC_API_KEY").merge("PAID_LLM_TEXT_MODE_DISABLED" => nil)) }

      it "returns an empty hash so subscription/OAuth billing is preserved" do
        expect(described_class.options).to eq({})
      end
    end

    context "when the kill switch is set" do
      before do
        stub_const("ENV", ENV.to_hash.merge(
          "ANTHROPIC_API_KEY" => "sk-ant-abc",
          "PAID_LLM_TEXT_MODE_DISABLED" => "1"
        ))
      end

      it "returns an empty hash even when the API key is present" do
        expect(described_class.options).to eq({})
      end
    end

    context "when the kill switch has a non-truthy value" do
      before do
        stub_const("ENV", ENV.to_hash.merge(
          "ANTHROPIC_API_KEY" => "sk-ant-abc",
          "PAID_LLM_TEXT_MODE_DISABLED" => "0"
        ))
      end

      it "still routes to text mode" do
        expect(described_class.options).to eq(mode: :text)
      end
    end
  end

  describe ".enabled?" do
    it "is a boolean" do
      expect(described_class.enabled?).to be_in([ true, false ])
    end
  end
end
