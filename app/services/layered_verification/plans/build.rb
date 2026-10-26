# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      HOST_GATES = [ "CI", "security", "branch protection", "code review", "approved-intent conformance" ].freeze

      def self.call(...) = new(...).call

      def initialize(checks:, omissions:, assumptions:, residual_gaps:)
        @checks, @omissions, @assumptions, @residual_gaps = checks, omissions, assumptions, residual_gaps
      end

      def call
        { checks: checks.map { |check| check.symbolize_keys }, omissions: omissions.map { |omission| omission.symbolize_keys },
          assumptions:, residual_gaps:, host_gates: HOST_GATES }
      end

      private

      attr_reader :checks, :omissions, :assumptions, :residual_gaps
    end
  end
end
