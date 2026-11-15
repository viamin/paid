# frozen_string_literal: true

# frozen_string: true

module PartialCloseouts
  # Operator-facing read model for stopped automatic acceptance-audit
  # retries. Returns nil while a bounded retry is still admissible or
  # pending; otherwise states the classification reason and the supported
  # operator action so exhaustion never disappears silently.
  # @spec PARTIAL-CLOSEOUT-056
  class AuditRetryNotice
    Notice = Data.define(:reason, :explanation, :operator_action)

    OPERATOR_ACTIONS = {
      retry_exhausted: "Restore the runner or transport, then explicitly request a fresh acceptance audit.",
      invalid_input: "Repair the runner or audit input (source issue or delivery evidence), then request a fresh acceptance audit.",
      authentication_configuration: "Reconnect the configured runner credential, then request a fresh acceptance audit.",
      budget_exhausted: "Raise or wait for the project AI budget, then request a fresh acceptance audit.",
      non_transient_failure: "Inspect the failed audit run and request a fresh acceptance audit once its cause is fixed."
    }.freeze
    EXPLANATIONS = {
      retry_exhausted: "Automatic acceptance-audit retries stopped after three automatic audit attempts for the current evidence generation ended in transient transport failures.",
      invalid_input: "The last automatic acceptance audit failed with invalid or stale input, which a retry cannot repair.",
      authentication_configuration: "The last automatic acceptance audit could not authenticate with the configured runner.",
      budget_exhausted: "The last automatic acceptance audit stopped because the project budget was exhausted.",
      non_transient_failure: "The last automatic acceptance audit failed for a reason a retry cannot repair."
    }.freeze

    def self.call(issue, source_revision: nil, intent_revision: nil)
      source_revision ||= Assessment.source_revision_for(issue)
      intent_revision ||= Assessment.intent_revision_for(issue)
      reason = AcceptanceAuditRetryPolicy.sweep_decision(
        issue, source_revision:, intent_revision:
      ).refusal
      return nil unless OPERATOR_ACTIONS.key?(reason)

      Notice.new(reason, EXPLANATIONS.fetch(reason), OPERATOR_ACTIONS.fetch(reason))
    end
  end
end
