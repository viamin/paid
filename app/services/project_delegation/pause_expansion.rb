# frozen_string_literal: true

module ProjectDelegation
  # Records an RDR-080 expansion pause for a material reversal, a security,
  # tenant, or trust breach, or missing metric evidence, and routes one
  # focused blocking Inbox decision for human review. While unresolved, the
  # pause keeps the affected project's effective posture `conservative` and
  # blocks broadening.
  #
  # @spec PROJECT-DELEGATION-007
  class PauseExpansion
    class Error < StandardError; end
    class InvalidPauseReason < Error; end

    NOTIFICATION_SOURCE = "project_delegation_expansion_pause"

    def self.call(project:, reason:, detail:, evidence: {}, actor: nil)
      reason = reason.to_s
      unless ExpansionPause::REASONS.include?(reason)
        raise InvalidPauseReason, "pause reason must be one of #{ExpansionPause::REASONS.join(', ')}"
      end

      pause = nil
      project.account.transaction do
        pause = ExpansionPause.create!(
          account: project.account,
          project:,
          reason:,
          posture_before: ExpansionGuard.effective_posture(project),
          detail:,
          evidence:,
          paused_by: actor
        )
        Audit::RecordEvent.call(
          action: "project_delegation.expansion_paused",
          actor: actor,
          subject: pause,
          metadata: { "reason" => reason, "posture_before" => pause.posture_before }
        )
      end
      publish_decision(pause)
      pause
    end

    def self.publish_decision(pause)
      Notifications::Publish.call(
        account: pause.account,
        source: NOTIFICATION_SOURCE,
        subject: pause.project,
        severity: :error,
        blocking: true,
        nav_section: "projects",
        title: "Project delegation expansion paused",
        description: "Expansion is paused for #{pause.project.name} (#{human_reason(pause.reason)}) " \
                     "pending human review. The project stays on the conservative posture.",
        metadata: decision_metadata(pause)
      )
    end

    def self.decision_metadata(pause)
      {
        "reason" => pause.reason,
        "pause_id" => pause.id,
        "posture_before" => pause.posture_before,
        "recommended_action" => "Review the pause evidence, then resolve the pause to restore the " \
                                "bounded_delivery posture; until then the project stays conservative."
      }.compact
    end

    def self.human_reason(reason)
      reason.humanize
    end

    private_class_method :publish_decision, :decision_metadata, :human_reason
  end
end
