# frozen_string_literal: true

require "rails_helper"

# @spec LID-RUNS-002
# @spec LID-RUNS-005
RSpec.describe Prompts::BuildForLidPlanning do
  describe "authored-intent weighting (named plan docs)" do
    let(:plan_docs) do
      [
        { name: "docs/rdrs/RDR-051-lid-aware-agent-runs.md" },
        { name: "docs/high-level-design.md" }
      ]
    end

    it "treats named plan docs as authored intent and includes the RDR mapping" do
      prompt = described_class.call(
        project_name: "Paid",
        project_description: "LID-aware agent orchestration for downstream repos.",
        plan_docs: plan_docs
      )

      expect(prompt).to include("Treat named plan docs as authored intent")
      expect(prompt).to include("docs/rdrs/RDR-051-lid-aware-agent-runs.md")
      expect(prompt).to include("Problem / context sections -> HLD problem statement and LLD context")
      expect(prompt).to include("Alternatives / decisions -> LLD decisions and alternatives with authored rationale")
      expect(prompt).to include("Validation / acceptance sections -> EARS specs")
    end

    it "instructs the agent that plan-doc decisions must NOT carry [inferred]" do
      prompt = described_class.call(
        project_name: "Paid",
        project_description: "",
        plan_docs: plan_docs
      )

      expect(prompt).to include("Decisions sourced from the named plan docs below are authored intent")
      expect(prompt).to include("no `[inferred]` marker")
    end
  end

  describe "without named plan docs" do
    it "tells the agent to reverse-engineer and mark everything [inferred]" do
      prompt = described_class.call(
        project_name: "Paid",
        project_description: "",
        plan_docs: []
      )

      expect(prompt).to include("No named plan docs were provided")
      expect(prompt).to include("reverse-engineer decisions from the codebase")
      expect(prompt).to include("mark each as `[inferred]`")
    end
  end

  describe "adoption vs refinement run-kind directives" do
    it "lists the adoption-only required outputs when adoption is true" do
      prompt = described_class.call(
        project_name: "acme/api",
        project_description: "",
        plan_docs: [],
        adoption: true
      )

      expect(prompt).to include("Adopt Linked-Intent Development for acme/api")
      expect(prompt).to include("the ## LID block")
      expect(prompt).to include("docs/arrows/index.yaml")
      expect(prompt).to include("docs/high-level-design.md (HLD)")
    end

    it "lists the refinement required outputs when adoption is false" do
      prompt = described_class.call(
        project_name: "acme/api",
        project_description: "",
        plan_docs: [],
        adoption: false
      )

      expect(prompt).to include("Refine Linked-Intent Development artifacts for acme/api")
      expect(prompt).to include("declares a ## LID block")
      expect(prompt).to include("at least one LLD under docs/intent/<segment>/")
    end

    it "defaults to adoption when the flag is omitted" do
      prompt = described_class.call(
        project_name: "acme/api",
        project_description: "",
        plan_docs: []
      )

      expect(prompt).to include("Adopt Linked-Intent Development for acme/api")
    end
  end

  describe ".project_description_for" do
    it "returns the project's description when present" do
      project = Struct.new(:description).new("LID-aware agent orchestration.")

      expect(described_class.project_description_for(project)).to eq("LID-aware agent orchestration.")
    end

    it "returns an empty string when the project has no description method" do
      project = Object.new

      expect(described_class.project_description_for(project)).to eq("")
    end
  end
end
