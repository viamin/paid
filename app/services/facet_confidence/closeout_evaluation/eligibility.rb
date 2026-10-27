# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # The typed notification that routes an operator to this evaluator is the
    # work this evaluator performs, not a prerequisite that must clear first.
    # Other human prerequisites remain blocking, including a mixed notification
    # that contains any non-evaluation work.
    # @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-022
    class Eligibility
      def self.blockers(status)
        status.blockers.reject { |blocker| evaluator_notification_blocker?(blocker) }
      end

      def self.evaluator_notification_blocker?(blocker)
        return false unless blocker.code == :human_prerequisite_notification

        notifications = Array(blocker.evidence["notifications"])
        notifications.any? && notifications.all? { |notification| evaluator_notification?(notification) }
      end
      private_class_method :evaluator_notification_blocker?

      def self.evaluator_notification?(notification)
        Array(notification.dig("metadata", "prerequisites")).any? do |prerequisite|
          prerequisite.is_a?(Hash) && prerequisite["workflow"] == PartialCloseouts::FACET_CONFIDENCE_EVALUATION_WORKFLOW
        end
      end
      private_class_method :evaluator_notification?
    end
  end
end
