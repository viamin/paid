# frozen_string_literal: true

module Inbox
  # Read model for actionable audit discrepancies. It intentionally exposes
  # evidence and choices without changing a finding's resolution state: chat,
  # acknowledgement, and deferral are discussion records, not authority.
  class LayeredVerificationFinding
    # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
    def self.call(...)
      new(...).call
    end

    def initialize(finding:)
      @finding = finding
    end

    def call
      {
        scope: finding.obligation.scope_description,
        source_reference: finding.obligation.external_identity,
        claims: finding.detail.fetch("claims", []),
        observed_behavior: finding.detail.fetch("observed_behavior", nil),
        limitations: finding.detail.fetch("limitations", []),
        question: finding.detail.fetch("question", "Review this discrepancy."),
        options: finding.detail.fetch("options", []),
        owner_actions: %w[discuss defer request_rerun request_repair],
        audit_runs: finding.observations.filter_map(&:agent_run_id).uniq,
        intent_reference: finding.obligation.approved_revision_reference,
        pending_persistence: finding.obligation.approval_state != "approved"
      }
    end

    private

    attr_reader :finding
  end
end
