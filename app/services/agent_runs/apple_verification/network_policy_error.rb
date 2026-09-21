# frozen_string_literal: true

module AgentRuns
  module AppleVerification
    # Raised when an Apple verification guest's network request violates the
    # resolved {GuestContract}. Carries a stable +category+ so callers can
    # distinguish a network-boundary denial from build, test, or worker
    # infrastructure failures.
    # @spec APPLE-NETWORK-003
    class NetworkPolicyError < StandardError
      CATEGORY = "network_policy"

      attr_reader :category

      def initialize(message, category: CATEGORY)
        @category = category
        super(message)
      end
    end
  end
end
