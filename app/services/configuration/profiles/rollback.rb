# frozen_string_literal: true

module Configuration
  module Profiles
    # Reverses a previously applied configuration-profile change using the
    # +previous_values+ recorded in the originating {AccountActivityEvent}'s
    # metadata. Builds an inverse {Plan} from those values and applies it via
    # {Applier}, which records its own +configuration_profile.reverted+
    # activity entry — so the undo is itself auditable. The reverted event
    # carries +reverted_from_activity_id+ pointing back at the originating
    # apply, so each revert can be paired with the change it reverses.
    # @spec CONFIG-PROFILES-008
    class Rollback
      def self.call(activity_event, actor: nil)
        new(activity_event, actor:).call
      end

      def initialize(activity_event, actor:)
        unless activity_event.is_a?(AccountActivityEvent)
          raise ArgumentError, "Expected an AccountActivityEvent, got #{activity_event.class}"
        end
        unless activity_event.action == Applier::APPLIED_ACTION
          raise ArgumentError,
                "Only configuration-profile applies can be rolled back (got #{activity_event.action.inspect})"
        end

        @activity_event = activity_event
        @actor = actor
      end

      def call
        project = activity_event.subject
        raise ArgumentError, "Activity subject is not a Project" unless project.is_a?(::Project)

        previous_values = activity_event.metadata&.dig("previous_values")
        raise ArgumentError, "Activity event has no recorded previous_values to restore" unless previous_values

        Applier.call(
          plan: reverse_plan_for(project, previous_values),
          project: project,
          actor: actor,
          action: Applier::REVERTED_ACTION,
          label: "Revert #{profile_name} posture",
          extra_metadata: { reverted_from_activity_id: activity_event.id }
        )
      end

      private

      attr_reader :activity_event, :actor

      def reverse_plan_for(project, previous_values)
        Plan.new(
          profile_name: "revert:#{profile_name}",
          changes: build_reverse_changes(project, previous_values),
          unmet_prerequisites: [],
          applied_overrides: {},
          authorization: []
        )
      end

      def build_reverse_changes(project, previous_values)
        context = Context.build(project:, actor: actor)
        previous_values.filter_map do |key, previous_value|
          next unless Settings.known_key?(key)

          descriptor = Settings.fetch(key)
          current = Settings.read(context, key)
          next if current == previous_value

          Change.new(key: key, from: current, to: previous_value, level: descriptor.level)
        end
      end

      def profile_name
        activity_event.metadata&.dig("profile").to_s.presence || "configuration_profile"
      end
    end
  end
end
