# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceRuns::BuildPrompt do
  def build_prompt(objective: nil, guidance: nil, scope: nil)
    described_class.call(objective:, guidance:, scope:)
  end

  # @spec MAINT-011
  it "requires an objective or nonblank guidance" do
    expect { build_prompt(guidance: "  ") }.to raise_error(ArgumentError)
    expect { build_prompt(scope: "app/a.rb") }.to raise_error(ArgumentError)
  end

  # @spec MAINT-012
  it "instructs the agent to resolve named scope targets before claiming coverage" do
    prompt = build_prompt(guidance: "Audit workflows A and B", scope: "workflows A and B")

    expect(prompt).to include("workflows A and B")
    expect(prompt).to match(/resolve each named target/i)
    expect(prompt).to match(/before claiming coverage/i)
  end

  # @spec MAINT-013
  it "requires an actionable clarification outcome for ambiguous or missing targets" do
    prompt = build_prompt(guidance: "Audit workflows A and B", scope: "workflows A and B")

    expect(prompt).to match(/ambiguous|cannot be resolved/i)
    expect(prompt).to match(/clarification/i)
    expect(prompt).to match(/not.*scan the (whole|entire) repository/i)
  end

  # @spec MAINT-014
  it "records an explicit broad scope when no scope is supplied" do
    prompt = build_prompt(guidance: "Audit for unused code")

    expect(prompt).to match(/broad-scope/i)
    expect(prompt).to match(/entire repository/i)
  end

  it "embeds the user guidance verbatim" do
    prompt = build_prompt(guidance: "Preserve the independent retry and failure policies")

    expect(prompt).to include("Preserve the independent retry and failure policies")
  end

  it "embeds recipe objective instructions for a recipe-driven run" do
    prompt = build_prompt(objective: "unnecessary_code", guidance: "Focus on workflows")

    expect(prompt).to match(/unused|unnecessary/i)
    expect(prompt).to include("Focus on workflows")
  end

  # @spec MAINT-017
  it "states the report-only boundary: source files stay unchanged and no findings is a success" do
    prompt = build_prompt(guidance: "Audit workflow A")

    expect(prompt).to match(/report-only/i)
    expect(prompt).to match(/do not modify/i)
    expect(prompt).to match(/no findings/i)
  end

  it "bounds recommendations to the requested scope while allowing supporting inspection elsewhere" do
    prompt = build_prompt(guidance: "Audit workflow A", scope: "app/workflows/a.rb")

    expect(prompt).to match(/callers|tests|design documents/i)
    expect(prompt).to match(/beyond the requested scope/i)
  end
end
