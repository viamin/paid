# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Produces a durable, inspectable selection record. Selection itself is
    # supplied by the bounded audit coordinator; this object keeps the host
    # policy structural and deliberately imposes neither a model nor a minimum
    # number of checks.
    class Build
      # @spec LAYERED-VERIFY-021
      Result = Data.define(:scope, :sources, :target_revision, :budget, :selected_checks, :omissions)

      def self.call(...)
        new(...).call
      end

      def initialize(scope:, sources:, target_revision:, budget:, checks:, omissions: [])
        @scope = scope.to_s
        @sources = Array(sources).map(&:to_s).reject(&:blank?).uniq
        @target_revision = target_revision.to_s
        @budget = Integer(budget)
        @checks = Array(checks)
        @omissions = Array(omissions)
      end

      def call
        validate!
        Result.new(scope:, sources:, target_revision:, budget:, selected_checks: normalized_checks, omissions: normalized_omissions)
      end

      private

      attr_reader :scope, :sources, :target_revision, :budget, :checks, :omissions

      def validate!
        raise ArgumentError, "scope is required" if scope.blank?
        raise ArgumentError, "at least one source is required" if sources.empty?
        raise ArgumentError, "target_revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.positive?
        raise ArgumentError, "at least one selected check or explained omission is required" if checks.empty? && omissions.empty?
      end

      def normalized_checks
        checks.map { |check| normalize(check, required: %w[producer fit]) }
      end

      def normalized_omissions
        omissions.map { |omission| normalize(omission, required: %w[producer reason]) }
      end

      def normalize(value, required:)
        hash = value.to_h.deep_stringify_keys.slice(*required, "assumptions", "limitations", "required_inputs", "resource_expectations")
        required.each { |key| raise ArgumentError, "#{key} is required" if hash[key].blank? }
        hash
      end
    end
  end
end
