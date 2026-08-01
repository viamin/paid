# frozen_string_literal: true

require "rails_helper"

RSpec.describe Lid::CoherenceSection do
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
