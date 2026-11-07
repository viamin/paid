# frozen_string_literal: true

module ProjectDelegation
  # Pauses delegation-pilot expansion for one enrolled project and returns it
  # to the `conservative` default pending human review (RDR-080): a material
  # reversal attributable to delegated work, a security/tenant/trust breach,
  # or missing metric evidence. The pause preserves every snapshot and audit
  # record, records an account activity event, and routes one blocking Inbox
  # decision describing the condition a human must review.
  #
  # @spec PROJECT-DELEGATION-007
  class PauseExpansion
    NOTIFICATION_SOURCE = "delegation_pilot_expansion_pause"
    REASONS = DelegationPilotEnrollment::PAUSE_REASONS

    Result = Data.define(:enrollment) do
      def paused? = enrollment.paused?
    end

    def self.call(enrollment:, reason:, evidence: {}, actor: nil)
      normalized = reason.to_s
      raise ArgumentError, "unknown pause reason: #{reason}" unless REASONS.include?(normalized)

      enrollment.with_lock do
        return Result.new(enrollment) if enrollment.paused? && enrollment.pause_reason == normalized

        enrollment.paused!(pause_reason: normalized, pause_evidence: evidence)
      end

      record_and_route(enrollment:, reason: normalized, evidence:, actor:)
      Result.new(enrollment)
    end

    class << self
      private

      def record_and_route(enrollment:, reason:, evidence:, actor:)
        Audit::RecordEvent.call(
          action: "delegation_pilot.paused",
          actor: actor,
          subject: enrollment,
          metadata: { "reason" => reason }.merge(evidence.stringify_keys)
        )
        Notifications::Publish.call(
          account: enrollment.account,
          subject: enrollment.project,
          source: NOTIFICATION_SOURCE,
          severity: :error,
          blocking: true,
          nav_section: "projects",
          title: "Delegated delivery pilot paused for #{reason.humanize.downcase}",
          description: "Broadening past conservative is paused for #{enrollment.project.name} pending human review." \
            " The project stays at its conservative default until the pause is reviewed.",
          metadata: { "reason" => reason, "enrollment_id" => enrollment.id }.merge(evidence.stringify_keys)
        )
      end
    end
  end
end
