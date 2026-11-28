# frozen_string_literal: true

module Lid
  # Formats the "## LID Coherence Soft-Block" markdown section surfaced in
  # PR bodies and PR update comments when an agent run's coherence check
  # failed. Shared by CreatePullRequestActivity and
  # CompleteExistingPrRunActivity so the two callers stay in sync.
  class CoherenceSection
    MAX_DETAIL_LINES = 12

    # @spec LID-RUNS-011
    def self.render(agent_run, closing_note:)
      coherence = agent_run.external_metadata["lid_coherence"]
      return if coherence.blank? || coherence["status"] != "failed"

      [
        "## LID Coherence Soft-Block",
        "",
        coherence["summary_line"],
        *detail_lines(coherence),
        "",
        closing_note
      ].join("\n")
    end

    # Actionable file/ID/base/head evidence lines (spec-ID collisions and
    # duplicate declarations), bounded so a large report cannot flood the
    # PR body.
    def self.detail_lines(coherence)
      details = Array(coherence["collision_details"]) + Array(coherence["duplicate_details"])
      return [] if details.empty?

      lines = details.first(MAX_DETAIL_LINES)
      remainder = details.size - lines.size
      lines << "… and #{remainder} more findings in the full report." if remainder.positive?
      [ "", *lines ]
    end
  end
end
