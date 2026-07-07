# frozen_string_literal: true

module Configuration
  module Profiles
    # Raised when an override references a key no profile declared as a
    # clarifying question. Arbitrary setting keys are never accepted (RDR-044).
    class UnknownOverrideError < ArgumentError; end

    # Deterministically diffs a project's current resolved state against a
    # profile's (override-merged) targets and produces a {Plan}.
    #
    # Responsibilities:
    # - Reject undeclared override keys (only declared clarifying-question ids).
    # - Merge declared overrides on top of the profile targets.
    # - Detect no-ops (a target already matches the current resolved value).
    # - Surface unmet prerequisites so {Applier} can refuse to run.
    class Planner
      def self.call(...) = new(...).call

      def initialize(profile:, project:, overrides: {})
        @profile = profile
        @project = project
        @overrides = stringify(overrides)
      end

      def call
        validate_override_keys!

        Plan.new(
          profile_name: profile.name,
          changes: build_changes(effective_targets),
          unmet_prerequisites: profile.prerequisites_for(project, targets: effective_targets),
          applied_overrides: applied_overrides
        )
      end

      private

      attr_reader :profile, :project, :overrides

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
        @applied_overrides ||= overrides.slice(*profile.override_keys)
      end

      def build_changes(targets)
        targets.filter_map do |key, target_value|
          current = Settings.read(project, key)
          next if current == target_value

          Change.new(key: key, from: current, to: target_value)
        end
      end

      def stringify(overrides)
        return {} unless overrides.is_a?(Hash)

        overrides.deep_stringify_keys
      end
    end
  end
end
