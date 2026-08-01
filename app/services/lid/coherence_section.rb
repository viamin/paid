# frozen_string_literal: true

module Lid
  # Formats the "## LID Coherence Soft-Block" markdown section surfaced in
  # PR bodies and PR update comments when an agent run's coherence check
  # failed. Shared by CreatePullRequestActivity and
  # CompleteExistingPrRunActivity so the two callers stay in sync.
  class CoherenceSection
    def self.render(agent_run, closing_note:)
      coherence = agent_run.external_metadata["lid_coherence"]
      return if coherence.blank? || coherence["status"] != "failed"

      [
        "## LID Coherence Soft-Block",
        "",
        coherence["summary_line"],
        "",
        closing_note
      ].join("\n")
    end
  end
end
