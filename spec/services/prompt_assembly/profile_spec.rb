# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-005, PROMPT-ASSEMBLY-009
RSpec.describe PromptAssembly::Profile, :no_db do
  def sec(key, required: false)
    PromptAssembly::Section.new(key: key, content: "x", required: required)
  end

  describe "#section_enabled?" do
    it "returns true for non-disabled sections" do
      profile = described_class.new
      expect(profile.section_enabled?(sec(:knowledge))).to be(true)
    end

    it "returns false for disabled optional sections" do
      profile = described_class.new(disabled_sections: [ :knowledge ])
      expect(profile.section_enabled?(sec(:knowledge))).to be(false)
    end

    it "returns true for required sections even when disabled" do
      profile = described_class.new(disabled_sections: [ :task ])
      expect(profile.section_enabled?(sec(:task, required: true))).to be(true)
    end
  end

  describe "#ordered_sections" do
    it "returns sections unchanged when no order is set" do
      profile = described_class.new
      sections = [ sec(:knowledge), sec(:style_guides) ]
      expect(profile.ordered_sections(sections)).to eq(sections)
    end

    it "sorts optional sections by the profile order" do
      profile = described_class.new(section_order: [ :style_guides, :knowledge ])
      sections = [ sec(:knowledge), sec(:style_guides) ]
      expect(profile.ordered_sections(sections).map(&:key)).to eq([ :style_guides, :knowledge ])
    end

    it "keeps required sections before optional sections" do
      profile = described_class.new(section_order: [ :knowledge ])
      sections = [ sec(:knowledge), sec(:task, required: true) ]
      expect(profile.ordered_sections(sections).map(&:key)).to eq([ :task, :knowledge ])
    end

    it "places unknown optional sections after ordered ones" do
      profile = described_class.new(section_order: [ :knowledge ])
      sections = [ sec(:marketplace), sec(:knowledge) ]
      expect(profile.ordered_sections(sections).map(&:key)).to eq([ :knowledge, :marketplace ])
    end
  end

  describe "#budget_for" do
    it "returns the budget for a configured section" do
      profile = described_class.new(budgets: { knowledge: { tokens: 2000 } })
      expect(profile.budget_for(:knowledge)).to eq({ tokens: 2000 })
    end

    it "returns default budget when not overridden" do
      profile = described_class.new
      expect(profile.budget_for(:knowledge)).to eq({ tokens: 4000 })
    end

    it "returns default budget when section not explicitly set" do
      profile = described_class.new(budgets: { style_guides: { bytes: 8000 } })
      expect(profile.budget_for(:knowledge)).to eq({ tokens: 4000 })
      expect(profile.budget_for(:style_guides)).to eq({ bytes: 8000 })
    end

    it "returns nil for non-budgetable sections" do
      profile = described_class.new
      expect(profile.budget_for(:task)).to be_nil
    end
  end

  describe "#fingerprint" do
    it "produces a stable 64-char hex string" do
      profile = described_class.new(disabled_sections: [ :knowledge ])
      expect(profile.fingerprint).to be_a(String)
      expect(profile.fingerprint.length).to eq(64)
    end

    it "produces identical fingerprints for identical profiles" do
      p1 = described_class.new(disabled_sections: [ :knowledge ], section_order: [ :style_guides ])
      p2 = described_class.new(disabled_sections: [ :knowledge ], section_order: [ :style_guides ])
      expect(p1.fingerprint).to eq(p2.fingerprint)
    end

    it "produces different fingerprints for different profiles" do
      p1 = described_class.new(disabled_sections: [ :knowledge ])
      p2 = described_class.new(disabled_sections: [ :style_guides ])
      expect(p1.fingerprint).not_to eq(p2.fingerprint)
    end

    it "is order-independent for disabled_sections (sorted internally)" do
      p1 = described_class.new(disabled_sections: [ :knowledge, :style_guides ])
      p2 = described_class.new(disabled_sections: [ :style_guides, :knowledge ])
      expect(p1.fingerprint).to eq(p2.fingerprint)
    end
  end

  describe "#merge" do
    it "combines disabled sections" do
      base = described_class.new(disabled_sections: [ :knowledge ])
      override = described_class.new(disabled_sections: [ :style_guides ])
      merged = base.merge(override)

      expect(merged.disabled_sections).to contain_exactly(:knowledge, :style_guides)
    end

    it "uses override section_order when present" do
      base = described_class.new(section_order: [ :knowledge ])
      override = described_class.new(section_order: [ :style_guides ])
      merged = base.merge(override)

      expect(merged.section_order).to eq([ :style_guides ])
    end

    it "keeps base section_order when override is empty" do
      base = described_class.new(section_order: [ :knowledge ])
      override = described_class.new
      merged = base.merge(override)

      expect(merged.section_order).to eq([ :knowledge ])
    end

    it "merges budgets with override taking precedence" do
      base = described_class.new(budgets: { knowledge: { tokens: 4000 } })
      override = described_class.new(budgets: { knowledge: { tokens: 2000 } })
      merged = base.merge(override)

      expect(merged.budget_for(:knowledge)).to eq({ tokens: 2000 })
    end
  end

  describe ".default" do
    it "includes default budgets" do
      profile = described_class.default
      expect(profile.budget_for(:knowledge)).to eq({ tokens: 4000 })
      expect(profile.budget_for(:style_guides)).to eq({ bytes: 32_000 })
    end

    it "has no disabled sections" do
      expect(described_class.default.disabled_sections).to eq([])
    end
  end
end
