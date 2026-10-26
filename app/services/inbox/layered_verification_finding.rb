# frozen_string_literal: true

module Inbox
  class LayeredVerificationFinding
    # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
    Snapshot = Data.define(:waiting_since, :summary, :detail)

    def self.call(...) = new(...).call

    def initialize(finding:)
      @finding = finding
    end

    def call
      Snapshot.new(waiting_since: finding.created_at, summary:, detail:)
    end

    private

    attr_reader :finding

    def summary = "#{finding.correspondence_claim_type.humanize}: #{finding.obligation.scope_description}"

    def detail
      {
        scope: finding.obligation.scope_description, source_reference: finding.obligation.external_identity,
        source_passages: finding.source_passages, observed_behavior: finding.observed_behavior,
        limitations: finding.limitations, evidence: finding.evidence, audit_run_id: finding.agent_run_id,
        status: finding.status, decision: finding.decision,
        actions: [
          { name: "propose_clarification", consequence: "Creates a draft only; repository persistence and approval remain required." },
          { name: "defer", consequence: "Keeps the discrepancy open and visible." },
          { name: "request_rerun", consequence: "Collects fresh audit evidence only." }
        ]
      }
    end
  end
end
