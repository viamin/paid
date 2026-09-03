# frozen_string_literal: true

module Configuration
  module Profiles
    # Deterministically diffs a project's current resolved state against a
    # profile's (override-merged) targets and produces a {Plan}.
    # @spec CONFIG-PROFILES-003
    #
    # Responsibilities:
    # - Reject undeclared override keys (only declared clarifying-question ids).
    # - Merge declared overrides on top of the profile targets.
    # - Detect no-ops (a target already matches the current resolved value).
    # - Surface unmet prerequisites so {Applier} can refuse to run.
    class Planner
      def self.call(...) = new(...).call

      def initialize(profile:, project:, overrides: {}, actor: nil)
        @profile = profile
        @project = project
        @overrides = stringify(overrides)
        @actor = actor
      end

      def call
        validate_override_keys!

        changes = build_changes(effective_targets)
        Plan.new(
          profile_name: profile.name,
          changes: changes,
          unmet_prerequisites: profile.prerequisites_for(project, targets: effective_targets),
          applied_overrides: applied_overrides,
          authorization: Authorization.call(actor:, context:, changes:)
        )
      end

      private

      attr_reader :profile, :project, :overrides, :actor

      def validate_override_keys!
        unknown = overrides.keys - profile.override_keys
        return if unknown.empty?

        raise UnknownOverrideError,
              "Profile #{profile.name.inspect} does not declare override keys: #{unknown.join(', ')}"
      end

      def effective_targets
        @effective_targets ||= profile.targets.deep_stringify_keys.merge(applied_overrides)
      end

      def applied_overrides
        @applied_overrides ||= overrides.slice(*profile.override_keys).to_h do |key, value|
          [ key, Settings.normalize(key, value) ]
        end
      end

      def build_changes(targets)
        targets.filter_map do |key, target_value|
          next unless Settings.known_key?(key)

          descriptor = Settings.fetch(key)
          current = Settings.read(context, key)
          next if current == target_value

          Change.new(key: key, from: current, to: target_value, level: descriptor.level)
        end
      end

      def stringify(overrides)
        raise ArgumentError, "overrides must be a Hash, got #{overrides.class}" unless overrides.is_a?(Hash)

        overrides.deep_stringify_keys
      end

      def context
        @context ||= Context.build(project:, actor:)
      end
    end
  end
end
