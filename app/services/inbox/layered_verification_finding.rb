# frozen_string_literal: true

module Inbox
  class LayeredVerificationFinding
    # @spec LAYERED-VERIFY-015
    # @spec LAYERED-VERIFY-016
    def initialize(finding:)
      @finding = finding
    end

    def detail
      {
        scope: finding.obligation.scope_description,
        source_reference: finding.obligation.external_identity,
        conflicting_claim: finding.correspondence_claim&.attributes&.slice("claim_type", "source_reference", "target_reference"),
        source_passages: finding.source_passages,
        observed_behavior: finding.observed_behavior,
        limitations: finding.limitations,
        observations: finding.observations.order(:created_at).map { |item| item.details.merge("at" => item.created_at) },
        resolution: "Discussion, acknowledgment, and deferral leave this discrepancy open; canonical intent approval and repair are separate actions."
      }
    end

    private

    attr_reader :finding
  end
end
