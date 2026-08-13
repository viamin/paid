# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::OutputNormalizer do
  let(:normalizer) { Class.new { include Llm::OutputNormalizer }.new }

  describe "#strip_surrounding_quotes" do
    it "strips ASCII double quotes" do
      expect(normalizer.strip_surrounding_quotes('"hello world"')).to eq("hello world")
    end

    it "strips ASCII single quotes" do
      expect(normalizer.strip_surrounding_quotes("'hello world'")).to eq("hello world")
    end

    it "strips backticks" do
      expect(normalizer.strip_surrounding_quotes("`hello world`")).to eq("hello world")
    end

    it "strips curly double quotes" do
      expect(normalizer.strip_surrounding_quotes("\u201Chello world\u201D")).to eq("hello world")
    end

    it "strips curly single quotes" do
      expect(normalizer.strip_surrounding_quotes("\u2018hello world\u2019")).to eq("hello world")
    end

    it "returns text unchanged when no quotes are present" do
      expect(normalizer.strip_surrounding_quotes("hello world")).to eq("hello world")
    end

    it "only strips the first matching pair" do
      expect(normalizer.strip_surrounding_quotes(%("'inner'"))).to eq("'inner'")
    end
  end

  describe "#strip_markdown_fence" do
    it "strips a markdown code fence" do
      text = "```markdown\n## Summary\n\nSome text\n```"
      expect(normalizer.strip_markdown_fence(text)).to eq("## Summary\n\nSome text")
    end

    it "returns text unchanged when no fence is present" do
      text = "## Summary\n\nSome text"
      expect(normalizer.strip_markdown_fence(text)).to eq(text)
    end

    it "handles a bare code fence without language" do
      text = "```\nContent\n```"
      expect(normalizer.strip_markdown_fence(text)).to eq("Content")
    end
  end
end
