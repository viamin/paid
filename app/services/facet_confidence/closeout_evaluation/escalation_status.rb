# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # An Action Required entry may itself be the human prerequisite resolved by
    # the evaluation. Ignore that one notification only after the controller
    # has validated its Inbox entry; every other closeout blocker still holds.
    # @spec FACET-CONFIDENCE-022
    class EscalationStatus
      def self.call(...) = new(...).call

      def initialize(status:, notification_id:)
        @status = status
        @notification_id = notification_id
      end

      def call
        return status unless only_selected_notification_blocks?

        status.dup.tap { |copy| copy.blockers = status.blockers.reject { |blocker| blocker == notification_blocker } }
      end

      private

      attr_reader :status, :notification_id

      def notification_blocker
        @notification_blocker ||= status.blockers.find { |blocker| blocker.code == :human_prerequisite_notification }
      end

      def only_selected_notification_blocks?
        return false unless notification_blocker

        ids = Array(notification_blocker.evidence&.fetch("notifications", [])).pluck("notification_id")
        ids == [ notification_id ]
      end
    end
  end
end
