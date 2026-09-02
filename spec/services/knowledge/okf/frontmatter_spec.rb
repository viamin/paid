# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-OKF-002
# @spec KNOWLEDGE-OKF-004
# @spec KNOWLEDGE-OKF-005
RSpec.describe Knowledge::Okf::Frontmatter do
  describe ".render and .parse" do
    it "round-trips frontmatter and body through render then parse" do
      rendered = described_class.render(
        frontmatter: { "title" => "Auth flows", "type" => "concept", "tags" => %w[auth security] },
        body: "Users sign in with SSO."
      )

      result = described_class.parse(rendered)

      expect(result).to be_valid
      expect(result.frontmatter).to eq("title" => "Auth flows", "type" => "concept", "tags" => %w[auth security])
      expect(result.body).to eq("Users sign in with SSO.")
    end

    it "renders nested hashes as YAML mappings that parse back cleanly" do
      rendered = described_class.render(
        frontmatter: { "title" => "Billing", "paid" => { "kb_uri" => "https://paid.example/knowledge_artifacts/1" } },
        body: "Usage-based billing."
      )

      result = described_class.parse(rendered)

      expect(result.frontmatter.dig("paid", "kb_uri")).to eq("https://paid.example/knowledge_artifacts/1")
    end
  end

  describe ".parse" do
    it "rejects content missing frontmatter delimiters" do
      result = described_class.parse("# Just markdown\n\nNo frontmatter.\n")

      expect(result).not_to be_valid
      expect(result.error).to eq("missing YAML frontmatter delimiters")
    end

    it "rejects non-mapping frontmatter" do
      result = described_class.parse("---\n- one\n- two\n---\n\nBody.\n")

      expect(result).not_to be_valid
      expect(result.error).to eq("frontmatter must be a YAML mapping")
    end

    it "rejects an empty body" do
      result = described_class.parse("---\ntitle: Empty\n---\n\n")

      expect(result).not_to be_valid
      expect(result.error).to eq("empty concept body")
    end

    it "rejects malformed frontmatter YAML" do
      result = described_class.parse("---\ntitle: Broken\n  bad: [unclosed\n---\n\nBody.\n")

      expect(result).not_to be_valid
      expect(result.error).to include("invalid frontmatter YAML")
    end
  end
end
