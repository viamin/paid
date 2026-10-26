# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      Check = Data.define(:producer, :fit, :required_inputs, :assumptions, :resource_expectations, :residual_gaps)
      Plan = Data.define(:checks, :omissions)

      # @spec LAYERED-VERIFY-021
      def self.call(...) = new(...).call

      def initialize(checks:, omissions:)
        @checks = checks
        @omissions = omissions
      end

      def call
        Plan.new(checks: checks.map { |check| build_check(check) }, omissions: omissions.map(&:symbolize_keys))
      end

      private

      attr_reader :checks, :omissions

      def build_check(check)
        values = check.symbolize_keys
        Check.new(**values.slice(*Check.members))
      end
    end
  end
end
