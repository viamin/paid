# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::BuildForLidPlanning do
  let(:project) { build_stubbed(:project, name: "test-project", owner: "owner-1", repo: "repo-1") }

  describe ".call" do
    it "builds a prompt containing the brownfield procedure" do
      prompt = described_class.call(project: project)

      expect(prompt).to include("brownfield analysis")
      expect(prompt).to include("docs-only")
      expect(prompt).to include("docs/high-level-design.md")
      expect(prompt).to include("docs/intent/")
    end

    it "includes instructions for the Planning PR" do
      prompt = described_class.call(project: project)

      expect(prompt).to include("Planning Pull Request")
      expect(prompt).to include("lid/planning-bootstrap")
      expect(prompt).to include("docs: bootstrap LID design tree")
    end

    it "includes the LID block addition instruction" do
      prompt = described_class.call(project: project)

      expect(prompt).to include("## LID")
      expect(prompt).to include("- Mode: Full")
      expect(prompt).to include("- Version: 1.3.0")
    end

    it "includes [inferred] marker guidance" do
      prompt = described_class.call(project: project)

      expect(prompt).to include("[inferred]")
      expect(prompt).to include("authored rationale")
    end

    it "includes EARS spec drafting guidance" do
      prompt = described_class.call(project: project)

      expect(prompt).to include("EARS")
      expect(prompt).to include("[x]")
      expect(prompt).to include("[ ]")
      expect(prompt).to include("[D]")
    end

    it "includes edge audit and coherence verification steps" do
      prompt = described_class.call(project: project)

      expect(prompt).to include("edge audit")
      expect(prompt).to include("coherence")
      expect(prompt).to include("bin/coherence-check.mjs")
    end

    it "prohibits code changes outside docs/" do
      prompt = described_class.call(project: project)

      expect(prompt).to include("Docs only")
      expect(prompt).to include("Do not create, modify, or delete any source code")
    end

    it "renders a valid non-empty prompt" do
      prompt = described_class.call(project: project)

      expect(prompt).to be_a(String)
      expect(prompt.length).to be > 100
    end
  end

  describe ".call with plan_doc_source" do
    it "injects the named plan document as authored intent" do
      prompt = described_class.call(project: project, plan_doc_source: "docs/rdrs/RDR-051.md")

      expect(prompt).to include("User-specified plan document")
      expect(prompt).to include("docs/rdrs/RDR-051.md")
      expect(prompt).to include("authored rationale")
    end

    it "places the plan-doc section before the brownfield procedure" do
      prompt = described_class.call(project: project, plan_doc_source: "docs/rdrs/RDR-051.md")

      expect(prompt.index("User-specified plan document")).to be < prompt.index("brownfield analysis")
    end

    it "omits the plan-doc section when the source is blank" do
      prompt = described_class.call(project: project, plan_doc_source: "   ")

      expect(prompt).not_to include("User-specified plan document")
    end

    it "strips surrounding whitespace from the plan-doc source" do
      prompt = described_class.call(project: project, plan_doc_source: "  docs/plan.md  ")

      expect(prompt).to include("docs/plan.md")
      expect(prompt).not_to include("docs/plan.md  ")
    end
  end

end
