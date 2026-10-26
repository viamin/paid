# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Builds a transparent, bounded execution contract. Selection itself is
    # supplied by the bounded assessment; this class deliberately does not
    # infer quality from check names or impose a minimum number of layers.
    # @spec LAYERED-VERIFY-021
    class Build
      def self.call(...) = new(...).call

      def initialize(scope:, selected_checks:, omissions:, budget:)
        @scope = scope
        @selected_checks = selected_checks
        @omissions = omissions
        @budget = budget
      end

      def call
        validate!
        { scope:, selected_checks:, omissions:, budget: }
      end

      private

      attr_reader :budget, :omissions, :scope, :selected_checks

      def validate!
        raise ArgumentError, "scope is required" if scope.blank?
        raise ArgumentError, "budget must be positive" unless budget.to_i.positive?
        invalid = selected_checks - LayeredVerificationCheckResult::PRODUCERS
        raise ArgumentError, "unknown checks: #{invalid.join(', ')}" if invalid.any?
      end
    end
  end
end
