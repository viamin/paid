# frozen_string_literal: true

require "rails_helper"

RSpec.describe Lid::CoherenceSection do
  let(:coherence_metadata) do
    {
      "status" => "failed",
      "summary_line" => "Coherence soft-block: 2 spec ID collisions, 1 duplicate spec declarations.",
      "collision_details" => [
        "SUBSCRIPTION-RUNNER-AUTH-008",
        "  head: docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:6",
        "  target: docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:5",
        "  @spec in head: app/services/subscription_runners/materialize.rb:4"
      ],
      "duplicate_details" => [
        "SUBSCRIPTION-RUNNER-AUTH-008: docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:5, " \
          "docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:6 (integration tree 0f1e2d, textual auto-merge)"
      ]
    }
  end

  describe ".render" do
    it "renders the soft-block section with the caller-specific closing note" do
      agent_run = build(:agent_run, external_metadata: {
        "lid_coherence" => {
          "status" => "failed",
          "summary_line" => "Coherence soft-block: 1 reverse orphan."
        }
      })

      section = described_class.render(agent_run, closing_note: "Caller-specific note.")

      expect(section).to include("## LID Coherence Soft-Block")
      expect(section).to include("Coherence soft-block: 1 reverse orphan.")
      expect(section).to include("Caller-specific note.")
    end

    it "renders collision detail evidence with the summary" do
      agent_run = build(:agent_run, external_metadata: {
        "lid_coherence" => coherence_metadata
      })

      section = described_class.render(agent_run, closing_note: "Advisory note.")

      expect(section).to include("2 spec ID collisions")
      expect(section).to include("SUBSCRIPTION-RUNNER-AUTH-008")
      expect(section).to include("docs/intent/subscription-runner-auth/subscription-runner-auth-specs.md:6")
      expect(section).to include("integration tree 0f1e2d")
      expect(section).to include("Advisory note.")
    end

    it "bounds the rendered detail evidence" do
      agent_run = build(:agent_run, external_metadata: {
        "lid_coherence" => {
          "status" => "failed",
          "summary_line" => "Coherence soft-block: 20 spec ID collisions.",
          "collision_details" => 30.times.map { |i| "COLLISION-ID-#{format('%03d', i)}" }
        }
      })

      section = described_class.render(agent_run, closing_note: "Advisory note.")

      expect(section.scan(/COLLISION-ID-/).size).to eq(described_class::MAX_DETAIL_LINES)
      expect(section).to include("more findings")
    end

    it "returns nil when there is no coherence metadata" do
      agent_run = build(:agent_run, external_metadata: {})

      expect(described_class.render(agent_run, closing_note: "note")).to be_nil
    end

    it "returns nil when the coherence check did not fail" do
      agent_run = build(:agent_run, external_metadata: {
        "lid_coherence" => { "status" => "passed", "summary_line" => "All good." }
      })

      expect(described_class.render(agent_run, closing_note: "note")).to be_nil
    end
  end
end
