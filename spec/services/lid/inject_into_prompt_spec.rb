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
    expect(prompt).to include("may vary by project")
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
end
