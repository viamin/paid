# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Builds an explicit, bounded plan. Selection is deliberately supplied by
    # the caller/agent rather than inferred from artifact names: whether a
    # check fits an obligation is a semantic judgment, not a keyword rule.
    # @spec LAYERED-VERIFY-021
    class Build
      Plan = Data.define(:checks, :exclusions, :residual_gaps, :revision)

      def self.call(...)
        new(...).call
      end

      def initialize(checks:, exclusions: [], residual_gaps: [], revision: nil)
        @checks = Array(checks)
        @exclusions = Array(exclusions)
        @residual_gaps = Array(residual_gaps)
        @revision = revision
      end

      def call
        Plan.new(checks: normalized_checks, exclusions: normalized_exclusions,
          residual_gaps: residual_gaps, revision: revision)
      end

      private

      attr_reader :checks, :exclusions, :residual_gaps, :revision

      def normalized_checks
        checks.map { |check| normalize_check(check) }
      end

      def normalized_exclusions
        exclusions.map { |exclusion| normalize_exclusion(exclusion) }
      end

      def normalize_check(check)
        value = check.respond_to?(:to_h) ? check.to_h : check
        value.deep_stringify_keys.slice("producer", "fit", "required_inputs", "assumptions", "resource_expectations", "limitations")
      end

      def normalize_exclusion(exclusion)
        value = exclusion.respond_to?(:to_h) ? exclusion.to_h : exclusion
        value.deep_stringify_keys.slice("producer", "reason", "limitations")
      end
    end
  end
end
