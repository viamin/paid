# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::BuildForLidPlanning do
  it "weights named plan docs ahead of code inference and includes the RDR mapping" do
    prompt = described_class.call(
      project_name: "Paid",
      project_description: "LID-aware agent orchestration for downstream repos.",
      plan_docs: [
        { name: "docs/rdrs/RDR-051-lid-aware-agent-runs.md" },
        { name: "docs/high-level-design.md" }
      ]
    )

    expect(prompt).to include("Prioritize named plan docs over code inference")
    expect(prompt).to include("docs/rdrs/RDR-051-lid-aware-agent-runs.md")
    expect(prompt).to include("Problem / context sections -> HLD problem statement and LLD context")
    expect(prompt).to include("Alternatives / decisions -> LLD decisions and alternatives with authored rationale")
    expect(prompt).to include("Validation / acceptance sections -> EARS specs")
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
