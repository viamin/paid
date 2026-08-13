# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-001, PROMPT-ASSEMBLY-003, PROMPT-ASSEMBLY-004, PROMPT-ASSEMBLY-006
RSpec.describe PromptAssembly::TrustedInput, :no_db do
  describe "#initialize" do
    it "accepts all declared input kinds" do
      PromptAssembly::TrustedInput::KINDS.each do |kind|
        expect(
          described_class.new(kind: kind, source: kind, body: "x", trust: :trusted).kind
        ).to eq(kind)
      end
    end

    it "rejects unknown kinds and trust levels (fail closed)" do
      expect { described_class.new(kind: :unknown, source: :x, body: "x", trust: :trusted) }
        .to raise_error(ArgumentError, /unknown kind/)
      expect { described_class.new(kind: :comment, source: :x, body: "x", trust: :nope) }
        .to raise_error(ArgumentError, /unknown trust level/)
    end
  end

  describe "trust predicates" do
    it "distinguishes trusted, quarantined, and excluded inputs" do
      expect(described_class.new(kind: :tenant, source: :rules, body: "x", trust: :trusted)).to be_trusted
      expect(described_class.new(kind: :knowledge, source: :bundle, body: "x", trust: :quarantined)).to be_quarantined
      expect(described_class.new(kind: :comment, source: :conversation, body: nil, trust: :excluded)).to be_excluded
    end

    it "reports excluded inputs as not included" do
      input = described_class.new(kind: :comment, source: :conversation, body: nil, trust: :excluded)
      expect(input).not_to be_included
    end
  end

  describe "#provenance" do
    it "is nil for non-excluded inputs" do
      input = described_class.new(kind: :comment, source: :conversation, body: "x", trust: :trusted)
      expect(input.provenance).to be_nil
    end

    it "records counts/provenance only, never the body" do
      input = described_class.new(
        kind: :comment, source: :conversation, body: "secret instructions",
        trust: :excluded, login: "attacker", exclusion_reason: "author_not_in_allowlist"
      )

      provenance = input.provenance

      expect(provenance).to include(kind: :comment, source: :conversation, login: "attacker")
      expect(provenance).not_to have_key(:body)
      expect(provenance.values).not_to include("secret instructions")
    end
  end

  describe "#to_section" do
    it "produces a quarantined section for repository-derived content" do
      input = described_class.new(kind: :knowledge, source: :bundle, body: "docs here", trust: :quarantined)
      section = input.to_section(key: :knowledge)

      expect(section).to be_quarantined
      expect(section.render).to include(PromptAssembly::Section::QUARANTINE_NOTICE)
      expect(section.render).to include("docs here")
    end

    it "carries exclusion reason through to the section" do
      input = described_class.new(
        kind: :comment, source: :conversation, body: nil,
        trust: :excluded, login: "attacker", exclusion_reason: "author_not_in_allowlist"
      )

      expect(input.to_section).to be_excluded
      expect(input.to_section.exclusion_reason).to eq("author_not_in_allowlist")
    end
  end
end
