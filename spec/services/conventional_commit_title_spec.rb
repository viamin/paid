# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConventionalCommitTitle do
  describe ".normalize" do
    it "returns a normalized conventional commit title" do
      expect(described_class.normalize("Feat(quality): Pause low-quality automation"))
        .to eq("feat(quality): Pause low-quality automation")
    end

    it "supports breaking-change markers" do
      expect(described_class.normalize("feat!: Replace automation policy"))
        .to eq("feat!: Replace automation policy")
    end

    it "strips surrounding whitespace" do
      expect(described_class.normalize("  fix(agent-runs): Resume stalled runs  "))
        .to eq("fix(agent-runs): Resume stalled runs")
    end

    it "rejects titles that only contain a conventional commit inside non-conventional text" do
      expect(described_class.normalize("Fix #714: feat(quality): Pause low-quality automation")).to be_nil
    end

    it "rejects ordinary issue titles" do
      expect(described_class.normalize("Add queue monitoring dashboard")).to be_nil
    end
  end
end
