# frozen_string_literal: true

module Inbox
  class LayeredVerificationFinding
    # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
    Snapshot = Data.define(:finding) do
      def summary
        finding.question
      end

      def waiting_since
        finding.created_at
      end

      def detail
        {
          scope: finding.obligation.scope_description,
          source: finding.obligation.external_identity,
          source_passages: finding.source_passages,
          claims: finding.claims,
          observed_behavior: finding.observed_behavior,
          limitations: finding.observations.includes(:check_result).map { |observation| observation.check_result.limitations },
          question: finding.question,
          options: finding.options,
          consequences: finding.consequences,
          owner_actions: finding.owner_actions,
          audit_run_id: finding.agent_run_id,
          canonical_revision: finding.obligation.approved_revision_reference,
          pending_persistence: finding.obligation.approval_state != "approved"
        }
      end
    end

    def self.call(finding) = Snapshot.new(finding)
  end
end
