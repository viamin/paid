# frozen_string_literal: true

require "rails_helper"

# @spec LID-RUNS-007
RSpec.describe Lid::PlanningContract do
  let(:project) { build_stubbed(:project, lid_mode: nil) }
  let(:agent_run) { build_stubbed(:agent_run, goal: "lid_planning", project: project) }

  def contract(files)
    described_class.call(agent_run: agent_run, changed_files: files)
  end

  describe "adoption runs (project has no lid_mode)" do
    it "is valid when the full artifact set is present" do
      files = [
        "docs/high-level-design.md",
        "docs/intent/auth/auth-design.md",
        "docs/intent/auth/auth-specs.md",
        "docs/arrows/index.yaml",
        "AGENTS.md"
      ]

      result = contract(files)

      expect(result.valid?).to be true
      expect(result.missing).to eq([])
      expect(result.adoption?).to be true
    end

    it "accepts CLAUDE.md in place of AGENTS.md" do
      files = [
        "docs/high-level-design.md",
        "docs/intent/core/core-design.md",
        "docs/intent/core/core-specs.md",
        "docs/arrows/index.yaml",
        "CLAUDE.md"
      ]

      expect(contract(files).valid?).to be true
    end

    it "accepts .github/copilot-instructions.md as the instruction file" do
      files = [
        "docs/high-level-design.md",
        "docs/intent/core/core-design.md",
        "docs/intent/core/core-specs.md",
        "docs/arrows/index.yaml",
        ".github/copilot-instructions.md"
      ]

      expect(contract(files).valid?).to be true
    end

    it "is invalid when the HLD is missing" do
      files = [
        "docs/intent/auth/auth-design.md",
        "docs/intent/auth/auth-specs.md",
        "docs/arrows/index.yaml",
        "AGENTS.md"
      ]

      result = contract(files)

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/high-level design/))
    end

    it "is invalid when no LLD under docs/intent/ is present" do
      files = [
        "docs/high-level-design.md",
        "docs/arrows/index.yaml",
        "AGENTS.md"
      ]

      result = contract(files)

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/LLD under docs\/intent/))
    end

    it "is invalid when no EARS spec (*-specs.md) is present" do
      files = [
        "docs/high-level-design.md",
        "docs/intent/auth/auth-design.md",
        "docs/arrows/index.yaml",
        "AGENTS.md"
      ]

      result = contract(files)

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/EARS spec/))
    end

    it "is invalid when the instruction file (## LID block) is missing" do
      files = [
        "docs/high-level-design.md",
        "docs/intent/auth/auth-design.md",
        "docs/intent/auth/auth-specs.md",
        "docs/arrows/index.yaml"
      ]

      result = contract(files)

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/instruction file/))
    end

    it "is invalid when docs/arrows/index.yaml is missing" do
      files = [
        "docs/high-level-design.md",
        "docs/intent/auth/auth-design.md",
        "docs/intent/auth/auth-specs.md",
        "AGENTS.md"
      ]

      result = contract(files)

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/arrow index/))
    end

    it "reports all missing artifacts at once" do
      result = contract([])

      expect(result.valid?).to be false
      expect(result.missing.length).to eq(5)
    end
  end

  describe "refinement runs (project declares lid_mode)" do
    let(:project) { build_stubbed(:project, lid_mode: "full") }

    it "is valid with only an LLD and its EARS specs" do
      files = [
        "docs/intent/billing/billing-design.md",
        "docs/intent/billing/billing-specs.md"
      ]

      result = contract(files)

      expect(result.valid?).to be true
      expect(result.refinement?).to be true
    end

    it "does not require the HLD, arrow index, or instruction file" do
      files = [
        "docs/intent/billing/billing-design.md",
        "docs/intent/billing/billing-specs.md"
      ]

      result = contract(files)

      expect(result.missing).to eq([])
    end

    it "is invalid when no LLD under docs/intent/ is present" do
      result = contract([ "docs/high-level-design.md" ])

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/LLD under docs\/intent/))
    end

    it "is invalid when no EARS spec is present" do
      result = contract([ "docs/intent/billing/billing-design.md" ])

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/EARS spec/))
    end
  end

  describe "plan-doc weighting flag" do
    it "is true when the run carries a plan_doc_source" do
      run = build_stubbed(:agent_run, goal: "lid_planning", project: project,
                                       plan_doc_source: "docs/rdrs/RDR-051.md")

      result = described_class.call(agent_run: run, changed_files: full_adoption_set)

      expect(result.plan_doc_weighted).to be true
    end

    it "is true when external_metadata lists named plan docs" do
      run = build_stubbed(:agent_run, goal: "lid_planning", project: project,
                                       external_metadata: { "plan_docs" => [ { "name" => "docs/hld.md" } ] })

      result = described_class.call(agent_run: run, changed_files: full_adoption_set)

      expect(result.plan_doc_weighted).to be true
    end

    it "is false when no plan docs are named" do
      result = contract(full_adoption_set)

      expect(result.plan_doc_weighted).to be false
    end
  end

  def full_adoption_set
    [
      "docs/high-level-design.md",
      "docs/intent/auth/auth-design.md",
      "docs/intent/auth/auth-specs.md",
      "docs/arrows/index.yaml",
      "AGENTS.md"
    ]
  end
end
