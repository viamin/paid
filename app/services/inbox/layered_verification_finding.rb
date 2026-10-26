# frozen_string_literal: true

module Inbox
  # Read-only Inbox projection. Discussion and deferral are deliberately not
  # state transitions to resolved; canonical approval remains elsewhere.
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    def self.entries(projects:)
      ::LayeredVerificationFinding.where(project: projects, state: %w[open deferred])
        .includes(:project, :obligation, :originating_audit_run).order(:created_at, :id)
    end

    def self.summary(finding)
      "Decision needed: #{finding.decision_question}"
    end
  end
end
