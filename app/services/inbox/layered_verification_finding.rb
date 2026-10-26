# frozen_string_literal: true

module Inbox
  # Read-only Inbox projection; lifecycle actions deliberately do not mutate a
  # finding. Canonical approval and repair each have their own entry points.
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    def self.call(finding:)
      {
        source_passages: finding.source_passages,
        claims: finding.correspondence_claim&.slice(:claim_type, :source_reference, :target_reference),
        observed_behavior: finding.observed_behavior,
        limitations: finding.observations.includes(:check_result).filter_map { |observation| observation.check_result&.limitations }.uniq,
        question: finding.question,
        options: finding.options,
        consequences: finding.consequences,
        audit_run_id: finding.agent_run_id,
        obligation_reference: finding.obligation.external_identity,
        status: finding.status
      }
    end
  end
end
