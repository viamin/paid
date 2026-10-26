# frozen_string_literal: true

module Inbox
  # Builds the decision payload from persisted evidence. It intentionally has
  # no resolving operation: chat, acknowledgement, and deferral preserve the
  # discrepancy until fresh evidence supports an authoritative resolution.
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    Snapshot = Data.define(:finding, :checks, :actions)

    def self.call(...)
      new(...).call
    end

    def self.candidates(project_ids)
      ::LayeredVerificationFinding.where(project_id: project_ids).where.not(status: "resolved")
    end

    def initialize(finding:)
      @finding = finding
    end

    def call
      Snapshot.new(finding:, checks: check_payloads, actions: action_payloads)
    end

    private

    attr_reader :finding

    def check_payloads
      finding.observations.includes(:check_result).order(created_at: :desc).map do |observation|
        result = observation.check_result
        {
          execution_state: result.execution_state, obligation_coverage: result.obligation_coverage,
          evidence_ref: result.evidence_ref, limitations: observation.limitations,
          observed_at: observation.created_at
        }
      end
    end

    def action_payloads
      [
        { action: "discuss", consequence: "Discussion records context but does not resolve the discrepancy." },
        { action: "defer", consequence: "Deferral remains visible and does not resolve the discrepancy." },
        { action: "request_repair", consequence: "A separately authorized repair is required and is never started by this audit." },
        { action: "approve_clarification", consequence: "Approval must persist in the canonical intent before dependent repair." }
      ]
    end
  end
end
