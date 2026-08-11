# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec LID-RUNS-001
RSpec.describe Lid::InjectIntoPrompt do
  let(:base_prompt) { "# Task\n\nImplement the requested change." }

  it "returns the prompt unchanged when the project does not expose lid_mode" do
    project = OpenStruct.new

    expect(described_class.call(prompt: base_prompt, project: project)).to eq(base_prompt)
  end

  it "returns the prompt unchanged when lid_mode is blank" do
    project = OpenStruct.new(lid_mode: " ")

    expect(described_class.call(prompt: base_prompt, project: project)).to eq(base_prompt)
  end

  it "appends the LID-aware section when lid_mode is present" do
    project = OpenStruct.new(lid_mode: "full")

    prompt = described_class.call(prompt: base_prompt, project: project)

    expect(prompt).to include("## LID-Aware Workflow")
    expect(prompt).to include("Linked-Intent Development mode: `full`")
    expect(prompt).to include("docs/high-level-design.md")
    expect(prompt).to include("bin/coherence-check.mjs")
    expect(prompt).to include("materialize that intent into draft or updated LLD and EARS artifacts before or alongside code changes")
  end

  it "adds scoped mode guidance when the project is scoped" do
    project = OpenStruct.new(lid_mode: "scoped")

    prompt = described_class.call(prompt: base_prompt, project: project)

    expect(prompt).to include("## LID Scope")
    expect(prompt).to include("only walk the arrow for in-scope paths")
  end

  it "does not append the section more than once" do
    project = OpenStruct.new(lid_mode: "full")
    prompt = "#{base_prompt}\n\n## LID-Aware Workflow\n\nExisting guidance."

    expect(described_class.call(prompt:, project: project).scan("## LID-Aware Workflow").size).to eq(1)
  end

  describe "goal-aware prompt generation" do
    let(:project) { OpenStruct.new(lid_mode: "full") }

    it "returns the full contract for create_pr goal" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "create_pr")

      expect(prompt).to include("bin/coherence-check.mjs")
      expect(prompt).to include("@spec")
      expect(prompt).to include("materialize that intent")
    end

    it "returns the full contract for lid_planning goal" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "lid_planning")

      expect(prompt).to include("bin/coherence-check.mjs")
      expect(prompt).to include("@spec")
    end

    it "returns the full contract for create_feature goal" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "create_feature")

      expect(prompt).to include("bin/coherence-check.mjs")
      expect(prompt).to include("@spec")
    end

    it "returns the full contract when goal is nil (backward compatible)" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: nil)

      expect(prompt).to include("bin/coherence-check.mjs")
      expect(prompt).to include("@spec")
    end

    it "returns a trimmed prompt for enhance_issue goal" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "enhance_issue")

      expect(prompt).to include("## LID-Aware Workflow")
      expect(prompt).to include("Elicit missing intent")
      expect(prompt).not_to include("bin/coherence-check.mjs")
      expect(prompt).not_to include("@spec")
      expect(prompt).not_to include("materialize that intent")
    end

    it "returns a trimmed prompt for analyze_issue goal" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "analyze_issue")

      expect(prompt).to include("## LID-Aware Workflow")
      expect(prompt).to include("assess scope and complexity")
      expect(prompt).not_to include("bin/coherence-check.mjs")
      expect(prompt).not_to include("@spec")
      expect(prompt).not_to include("Walk the arrow")
    end

    it "returns a trimmed prompt for review goal" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "review")

      expect(prompt).to include("## LID-Aware Workflow")
      expect(prompt).to include("design docs")
      expect(prompt).to include("Do NOT walk spec traces")
      expect(prompt).to include("the system runs the coherence check")
      expect(prompt).not_to include("Walk the arrow")
      expect(prompt).not_to include("materialize that intent")
    end

    it "returns a trimmed prompt for create_issue goal" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "create_issue")

      expect(prompt).to include("## LID-Aware Workflow")
      expect(prompt).to include("well-formed issue")
      expect(prompt).not_to include("bin/coherence-check.mjs")
      expect(prompt).not_to include("@spec")
      expect(prompt).not_to include("Walk the arrow")
    end

    it "section_for class method accepts goal parameter" do
      section = described_class.section_for(project: project, goal: "enhance_issue")

      expect(section).to include("Elicit missing intent")
      expect(section).not_to include("bin/coherence-check.mjs")
    end

    it "returns the full contract for an unmapped goal instead of omitting the section" do
      prompt = described_class.call(prompt: base_prompt, project: project, goal: "some_future_goal")

      expect(prompt).to include("## LID-Aware Workflow")
      expect(prompt).to include("bin/coherence-check.mjs")
      expect(prompt).to include("@spec")
    end
  end
end
