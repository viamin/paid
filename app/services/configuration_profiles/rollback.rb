# frozen_string_literal: true

module ConfigurationProfiles
  # Reverses a previously applied configuration-profile change using the
  # values recorded by {Applier} in the originating {AccountActivityEvent}'s
  # +previous_values+ metadata. The reversal itself is applied through
  # {Applier} and records its own +configuration_profile.reverted+ activity
  # entry, so the undo is itself auditable and (in principle) undoable.
  class Rollback
    REVERTED_ACTION = "configuration_profile.reverted"
    APPLIED_ACTION = Applier::APPLIED_ACTION

    Result = Data.define(:project, :changes, :activity)

    class << self
      def call(activity_event, actor: nil)
        new(activity_event, actor:).call
      end
    end

    def initialize(activity_event, actor:)
      unless activity_event.is_a?(AccountActivityEvent)
        raise ArgumentError, "Expected an AccountActivityEvent, got #{activity_event.class}"
      end
      unless activity_event.action == APPLIED_ACTION
        raise ArgumentError, "Only posture applications can be rolled back (got #{activity_event.action.inspect})"
      end

      @activity_event = activity_event
      @actor = actor
    end

    def call
      project = activity_event.subject
      raise ArgumentError, "Activity subject is not a Project" unless project.is_a?(::Project)

      previous_values = activity_event.metadata&.dig("previous_values")
      raise ArgumentError, "Activity event has no recorded previous_values to restore" unless previous_values

      reverse_plan = Planner.for_values(
        project,
        previous_values,
        label: "Revert posture change",
        source: :configuration_profile_rollback
      )
      Applier.call(
        project,
        reverse_plan,
        actor:,
        action: REVERTED_ACTION,
        extra_metadata: {
          reverted_activity_id: activity_event.id,
          original_profile_key: activity_event.metadata["profile_key"]
        }
      )
    end

    private

    attr_reader :activity_event, :actor
  end
end
