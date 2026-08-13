# frozen_string_literal: true

module Configuration
  module Profiles
    # An immutable description of what {Applier} needs to do to bring a project
    # in line with a profile. Built by {Planner}.
    #
    # A plan is one of:
    # - {#blocked?}: prerequisites are unmet; {Applier} refuses to run.
    # - {#no_op?}: the project already matches the (override-merged) targets;
    #   {Applier} is a no-op.
    # - otherwise: {#changes} lists the concrete {Change}s to apply.
    class Plan
      def initialize(profile_name:, changes:, unmet_prerequisites:, applied_overrides:, authorization:)
        @profile_name = profile_name.to_s
        @changes = Array(changes).freeze
        @unmet_prerequisites = Array(unmet_prerequisites).map(&:to_s).freeze
        @applied_overrides = stringify(applied_overrides).freeze
        @authorization = Array(authorization).map { |entry| stringify(entry) }.freeze
        freeze
      end

      attr_reader :profile_name, :changes, :unmet_prerequisites, :applied_overrides, :authorization

      def no_op?
        changes.empty?
      end

      def blocked?
        unmet_prerequisites.any?
      end

      def skipped_levels
        authorization.reject { |entry| entry.fetch("allowed", false) }
      end

      private

      def stringify(value)
        return {} unless value.is_a?(Hash)

        value.deep_stringify_keys
      end
    end
  end
end
