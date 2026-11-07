# frozen_string_literal: true

module ProjectDelegation
  # Restores a paused delegation-pilot enrollment after the human review the
  # pause routed. Resuming re-opens measurement; it never broadens anything by
  # itself — broadening still has to pass `ExpansionGuard` against recorded
  # evidence. The reviewer is recorded on the account activity event.
  #
  # @spec PROJECT-DELEGATION-007
  class ResumePilotEnrollment
    Result = Data.define(:enrollment) do
      def active? = enrollment.active?
    end

    def self.call(enrollment:, actor:)
      raise ArgumentError, "resuming a paused pilot requires a human reviewer" if actor.blank?

      return Result.new(enrollment) unless enrollment.paused?

      prior_reason = enrollment.pause_reason
      enrollment.update!(
        status: "active",
        pause_reason: nil,
        paused_at: nil,
        pause_evidence: {}
      )
      Audit::RecordEvent.call(
        action: "delegation_pilot.resumed",
        actor: actor,
        subject: enrollment,
        metadata: { "prior_pause_reason" => prior_reason }
      )
      Result.new(enrollment)
    end
  end
end
