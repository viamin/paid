# frozen_string_literal: true

module Inbox
  class LayeredVerificationFinding
    # @spec LAYERED-VERIFY-015
    # @spec LAYERED-VERIFY-016
    Snapshot = Data.define(:finding, :summary, :detail, :actions)

    def self.call(finding)
      new(finding).call
    end

    def initialize(finding)
      @finding = finding
    end

    def call
      Snapshot.new(finding, summary, detail, actions)
    end

    private

    attr_reader :finding

    def summary
      "Verification discrepancy requires an owner decision."
    end

    def detail
      {
        obligation_scope: finding.obligation.scope_description,
        source_reference: finding.obligation.external_identity,
        source_passages: finding.source_passages,
        observed_behavior: finding.observed_behavior,
        limitations: finding.limitations,
        question: finding.question,
        options: finding.options,
        consequences: finding.consequences,
        audit_run_id: finding.originating_audit_run_id,
        intent_revision: finding.obligation.external_revision,
        observations: finding.observations.includes(:check_result).map do |observation|
          result = observation.check_result
          { observed_at: observation.observed_at, execution_state: result.execution_state, coverage: result.obligation_coverage, evidence_ref: result.evidence_ref }
        end
      }
    end

    def actions
      {
        discuss: "Discussion does not resolve this finding.",
        acknowledge: "Acknowledgment does not resolve this finding.",
        defer: "Deferral remains visible and does not resolve this finding.",
        clarify: "Canonical intent approval and persistence are required before a dependent repair.",
        repair: "A repair requires a separate explicit authorization."
      }
    end
  end
end
