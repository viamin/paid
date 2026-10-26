# frozen_string_literal: true

module LayeredVerification
  module Findings
    # Defers a finding with a recorded reason. Deferral is not resolution: the
    # finding stays open, keeps its history, and remains visible with the
    # reason and a route back to action.
    #
    # @spec LAYERED-VERIFY-016
    class Defer
      def self.call(...)
        new(...).call
      end

      def initialize(finding:, reason:, user: nil)
        @finding = finding
        @reason = reason
        @user = user
      end

      def call
        finding.update!(
          status: "deferred",
          deferral_reason: reason,
          deferred_at: Time.current
        )
        finding
      end

      private

      attr_reader :finding, :reason, :user
    end
  end
end
