# frozen_string_literal: true

module Inbox
  # Read-only Inbox projection. Discussion and deferral leave the finding open.
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    def self.call(finding:) = new(finding:).call

    def initialize(finding:)
      @finding = finding
    end

    def call
      {
        title: "Audit finding: #{finding.obligation.external_identity}",
        summary: finding.question,
        source_passages: finding.source_passages,
        claims: finding.claims,
        observed_behavior: finding.observed_behavior,
        check_limitations: finding.check_limitations,
        options: finding.options,
        owner_actions: finding.owner_actions,
        audit_run_id: finding.audit_run_id,
        obligation_id: finding.obligation_id,
        deferred: finding.deferred_at.present?
      }
    end

    private

    attr_reader :finding
  end
end
