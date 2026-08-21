# frozen_string_literal: true

class PromptAssembly::Sections::RdrRolloutGuard
  include PromptAssembly::Sections::Base

  private

  # @spec RDR-ROLLOUT-GUARD-002
  def build_section
    return "" unless issue_references_rdr?

    <<~PROMPT
      # RDR Rollout Guard

      If this issue references an RDR, read that RDR's `## Rollout Guard` before changing runtime behavior. Preserve the named feature flag, config gate, migration-only boundary, docs-only boundary, or explicit "none required" rationale. Do not make guarded behavior default unless the issue or RDR closeout explicitly asks for that cleanup.
    PROMPT
  end

  def inclusion_reason
    "RDR-backed work must keep incomplete runtime behavior guarded"
  end

  def skip_reason
    "issue does not reference an RDR"
  end

  def issue_references_rdr?
    [ issue.title, issue.body ].any? { |text| text.to_s.match?(/\bRDR-\d{3,}\b/i) }
  end
end
