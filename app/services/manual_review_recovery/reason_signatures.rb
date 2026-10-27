# frozen_string_literal: true

module ManualReviewRecovery
  # The canonical wording fragments that the producers use when they park an
  # issue in `manual_review`.
  #
  # `manual_review_reason` is free text by design (it is shown to operators),
  # so the classifier cannot match on "anything that looks like X". These
  # fragments are the producers' own fixed wording: each producer builds its
  # human-readable reason from one of them, so matching a fragment reads the
  # recorded provenance instead of guessing at its meaning.
  #
  # Keep the fragments in sync with the producers that write them:
  # `FetchIssuesActivity#dependency_blocked_reason`,
  # `EnhanceIssueActivity#max_rounds_reason`,
  # `QueueAgentRunActivity#stop_for_enhancement_limit`,
  # `EnhanceIssueActivity#raise_parse_error!`,
  # `PromptAssembly::BuildIssuePrompt#block_remediation!`, and
  # `SecurityAlerts::ProcessCodeScanningAlerts`.
  # @spec MANUAL-REVIEW-RECOVERY-001
  module ReasonSignatures
    # FetchIssuesActivity#dependency_blocked_reason
    DEPENDENCY_WAIT = "blocked on an unresolved dependency"
    # EnhanceIssueActivity#max_rounds_reason
    ENHANCEMENT_ROUND_LIMIT = "enhancement re-evaluation rounds"
    # QueueAgentRunActivity#stop_for_enhancement_limit
    ENHANCEMENT_QUEUE_LIMIT = "configured enhancement-round limit"
    # EnhanceIssueActivity#raise_parse_error!
    ENHANCEMENT_OUTPUT_INVALID = "could not validate the enhancement agent's structured output"
    # SecurityAlerts::ProcessCodeScanningAlerts /
    # SecurityAlerts::ReconcileResolved
    SCANNER_REMEDIATION_NOT_RECORDED = "scanner-verified remediation is not recorded"
    # SecurityAlerts::VerifyRemediationAttempt#fail!
    SCANNER_RECURRENCE = "scanner-confirmed recurrence"
    # PromptAssembly::BuildIssuePrompt#raise_evidence_error!
    SCANNER_EVIDENCE_BLOCKED = "Code scanning remediation blocked:"
    # PromptAssembly::BuildIssuePrompt#refresh_code_scanning_context
    SCANNER_EVIDENCE_REFRESH_FAILED = "evidence refresh failed:"
  end
end
