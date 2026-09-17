# frozen_string_literal: true

module DesignAmendments
  # Releases a design-amendment hold once the branch has been rechecked
  # against the new baseline or a human clears it. The hold's exclusion from
  # issue selection drops out with it.
  # @spec INTENT-AMENDMENT-009
  class ReleaseHold
    NOTIFICATION_SOURCE = EvaluateImpact::UNCERTAIN_NOTIFICATION_SOURCE

    def self.call(...)
      new(...).call
    end

    def initialize(pause:, actor:, reason:)
      @pause = pause
      @actor = actor
      @reason = reason
    end

    def call
      raise InvalidTransitionError, "hold is already released" unless pause.held?

      pause.transaction(requires_new: true) do
        pause.update!(
          status: "released",
          released_at: Time.current,
          released_by: actor,
          release_reason: reason
        )
        resolve_notification
      end
      pause
    end

    private

    attr_reader :pause, :actor, :reason

    def resolve_notification
      Notifications::Resolve.call(
        account: pause.issue.project.account,
        source: NOTIFICATION_SOURCE,
        subject: pause.issue
      )
    end
  end
end
