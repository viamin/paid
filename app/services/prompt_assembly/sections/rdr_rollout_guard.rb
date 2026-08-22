# frozen_string_literal: true

class PromptAssembly::Sections::RdrRolloutGuard
  include PromptAssembly::Sections::Base

  RDR_PATTERN = /\bRDR-\d{3,}\b/i

  private

  # @spec RDR-ROLLOUT-GUARD-002
  # @spec RDR-ROLLOUT-GUARD-003
  def build_section
    return "" unless issue_references_rdr?

    <<~PROMPT
      # RDR Rollout Guard

      If this issue references an RDR, read that RDR's `## Rollout Guard` before changing runtime behavior. Preserve the named feature flag, config gate, migration-only boundary, docs-only boundary, or explicit "none required" rationale. For feature flags, make sure the flag is listed in `FeatureFlags::DEFINITIONS`, has a named enablement surface, and guards the runtime decision with `FeatureFlags.enabled?(:flag_name, project:)`. Do not make guarded behavior default unless the issue or RDR closeout explicitly asks for that cleanup.
    PROMPT
  end

  def inclusion_reason
    "RDR-backed work must keep incomplete runtime behavior guarded"
  end

  def required
    true
  end

  def skip_reason
    "issue does not reference an RDR"
  end

  # Title and body reference RDRs, but a trusted collaborator comment can
  # also link the issue to an RDR. Mirror the comment trust policy from
  # {PromptAssembly::Trust.comment_trusted?} so untrusted commenters cannot
  # sway the guard decision via prompt-injected bodies.
  def issue_references_rdr?
    candidates = [ issue.title, issue.body, *trusted_comment_bodies ]
    candidates.any? { |text| text.to_s.match?(RDR_PATTERN) }
  end

  # Only comments admitted into the prompt reach the agent, so we use the
  # same trust predicate the conversation section uses. Without this, the
  # guard would be tied to a narrower allowlist than the rest of the prompt.
  def trusted_comment_bodies
    Array(issue_comments).select { |comment| PromptAssembly::Trust.comment_trusted?(project, comment) }
                          .map { |comment| comment.respond_to?(:body) ? comment.body : nil }
                          .compact
  end
end
