# frozen_string_literal: true

module Inbox
  # Read-only Inbox projection. Discussion and deferral intentionally have no
  # mutation API here; only fresh evidence can resolve a finding.
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    def self.entries(projects:)
      ::LayeredVerificationFinding.open.where(project: projects).includes(:project, :obligation, :agent_run).order(:created_at, :id).map do |finding|
        Queue::Entry.new(
          id: "#{Queue::LAYERED_VERIFICATION_FINDING_KIND}:#{finding.id}",
          kind: Queue::LAYERED_VERIFICATION_FINDING_KIND,
          project: finding.project,
          issue: nil,
          record: finding,
          waiting_since: finding.created_at,
          questions: [ "Choose an authoritative clarification, defer with a reason, or request a separately authorized repair." ],
          tasks: [ finding.obligation.scope_description, finding.limitations ],
          summary_text: "Verification discrepancy requires an owner decision; chat and acknowledgment do not resolve it.",
          title_text: "Verification finding: #{finding.obligation.external_identity}",
          action_url: nil
        )
      end
    end
  end
end
