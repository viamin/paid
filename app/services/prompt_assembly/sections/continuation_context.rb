# frozen_string_literal: true

# Deliberate continuation context: the operator's authorized reason and the
# closeout evidence snapshot the authorization was granted against (#4185).
#
# Present only when the run executes a scoped IssueContinuationRequest.
# Issues::RequestContinuation creates that request and its AgentRun in one
# transaction for both the Inbox action and the request_issue_continuation
# MCP tool, so reading agent_run.continuation_request here covers both
# surfaces uniformly without branching on how the run was requested.
#
# Required so a profile cannot suppress the authorized reason once a
# continuation request is present — the operator's remaining-work plan must
# reach the agent's instructions, not just the audit trail
# (IssueContinuationRequest / Audit::RecordEvent).
# @spec PARTIAL-CLOSEOUT-012
class PromptAssembly::Sections::ContinuationContext
  include PromptAssembly::Sections::Base

  private

  def build_section
    return "" unless continuation_request

    <<~PROMPT
      # Continuation Context

      This run is a deliberate continuation of issue ##{issue.github_number}, authorized by #{actor_label} (continuation request ##{continuation_request.id}).

      Prior work on this issue reached a terminal closeout outcome — a merged partial pull request and/or a no-code-required declaration — which normally keeps this issue out of automatic scheduling permanently. An authorized operator reviewed that outcome, judged that work remains, and explicitly requested this continuation.

      ## Evidence this continuation was authorized against (generation #{short_digest})

      #{evidence_summary}

      ## Operator's stated reason for continuing

      > #{reason}

      ## How to use this context

      - Treat the reason above as the actual remaining-work plan. Prioritize the specific gaps it names over re-deriving scope from scratch.
      - Do not re-do or re-verify the work already completed in the evidence above; focus on what the reason says is still missing.
      - If this issue is an epic or umbrella, do not treat closed child issues as sufficient evidence that it is done — verify the specific gaps named in the reason against the current repository state.
      - Leave this issue (and any related epic) open if the full scope named in the reason is not resolved by this run. Only close what you can evidence as actually complete.
    PROMPT
  end

  def required
    true
  end

  def inclusion_reason
    "deliberate continuation authorization and evidence snapshot"
  end

  def skip_reason
    "no_continuation_request"
  end

  def section_metadata
    return unless continuation_request

    {
      request_id: continuation_request.id,
      actor_id: continuation_request.requested_by_id,
      evidence_digest: continuation_request.evidence_digest,
      requested_at: continuation_request.created_at&.utc&.iso8601
    }
  end

  def continuation_request
    agent_run&.continuation_request
  end

  def reason
    continuation_request.reason.to_s.strip
  end

  def actor_label
    actor = continuation_request.requested_by
    return "an authorized operator" unless actor

    actor.name.presence || actor.email
  end

  def short_digest
    continuation_request.evidence_digest.to_s[0, 12]
  end

  def evidence_summary
    evidence = continuation_request.evidence || {}
    merged_prs = Array(evidence["merged_prs"])
    no_code_at = evidence["no_code_required_at"]

    lines = merged_prs.map { |pr| "- Merged pull request ##{pr["number"]}: #{pr["url"]}" }
    lines << "- No-code-required declared at: #{no_code_at}" if no_code_at.present?

    lines.presence&.join("\n") || "- No merged-PR or no-code evidence recorded."
  end
end
