# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-019
RSpec.describe FeatureIntents::RunDecisionEmissions do
  def emission_block(json)
    "<!-- feature-decisions-start -->\n#{json}\n<!-- feature-decisions-end -->"
  end

  it "parses explicitly emitted questions and inferred decisions" do
    summary = <<~TEXT
      Researched the repository and opened the RDR PR.

      #{emission_block(<<~JSON)}
        [
          {"kind": "question", "design_claim": "Dark mode applies to the settings UI", "prompt": "Should dark mode apply to the marketing pages too?"},
          {"kind": "inferred_decision", "design_claim": "Theme persistence is per user", "prompt": "Persisting the theme choice per user account rather than per device."}
        ]
      JSON
    TEXT

    items = described_class.parse(summary)

    expect(items.map(&:kind)).to eq(%w[question inferred_decision])
    expect(items.first.prompt).to eq("Should dark mode apply to the marketing pages too?")
    expect(items.first.design_claim).to eq("Dark mode applies to the settings UI")
  end

  it "flags inferred decisions with the [inferred] marker in prompt text" do
    summary = emission_block(
      '[{"kind": "inferred_decision", "design_claim": "Claim", "prompt": "Assuming X applies to new records only."}]'
    )

    items = described_class.parse(summary)

    expect(items.first.prompt).to eq("[inferred] Assuming X applies to new records only.")
  end

  it "does not duplicate the [inferred] marker when the emission already carries it" do
    summary = emission_block(
      '[{"kind": "inferred_decision", "design_claim": "Claim", "prompt": "[inferred] Assuming X applies to new records only."}]'
    )

    items = described_class.parse(summary)

    expect(items.first.prompt).to eq("[inferred] Assuming X applies to new records only.")
  end

  it "returns no items when the run emitted no decisions block (never fabricates)" do
    expect(described_class.parse("Researched and opened the RDR PR. No open questions.")).to be_empty
    expect(described_class.parse("")).to be_empty
    expect(described_class.parse(nil)).to be_empty
  end

  it "skips malformed or incomplete items rather than repairing them" do
    summary = emission_block(
      <<~JSON
        [
          {"kind": "question", "design_claim": "Claim", "prompt": "Valid question?"},
          {"kind": "question", "design_claim": "Missing prompt"},
          {"kind": "question", "prompt": "Missing design claim?"},
          {"kind": "unsupported_kind", "design_claim": "Claim", "prompt": "Unknown kind."},
          "not-an-object",
          {"kind": "inferred_decision", "design_claim": "Claim", "prompt": "Valid inference."}
        ]
      JSON
    )

    items = described_class.parse(summary)

    expect(items.map(&:kind)).to eq(%w[question inferred_decision])
    expect(items.map(&:prompt)).to include("Valid question?", "[inferred] Valid inference.")
  end

  it "returns no items when the emitted JSON cannot be parsed" do
    summary = emission_block("{not json at all")

    expect(described_class.parse(summary)).to be_empty
  end

  it "parses JSON wrapped in a markdown fence" do
    summary = emission_block(<<~JSON)
      ```json
      [{"kind": "question", "design_claim": "Claim", "prompt": "Fenced?"}]
      ```
    JSON

    expect(described_class.parse(summary).map(&:prompt)).to eq(%w[Fenced?])
  end

  it "caps the number of parsed decisions" do
    items = Array.new(described_class::MAX_DECISIONS + 5) do
      { kind: "question", design_claim: "Claim", prompt: "Question #{_1}?" }
    end
    summary = emission_block(JSON.generate(items))

    expect(described_class.parse(summary).size).to eq(described_class::MAX_DECISIONS)
  end

  it "reads only the marked block, ignoring [inferred] markers elsewhere in the output" do
    summary = "The RDR marks a database choice [inferred] in prose but emits no block."

    expect(described_class.parse(summary)).to be_empty
  end
end
