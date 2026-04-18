# frozen_string_literal: true

module Automation
  module ReviewMethods
    # Manual reviewer — a human GitHub user configured per-project via
    # +review_settings.methods.manual.reviewer_login+. Paid requests the
    # reviewer and then waits for an APPROVED review before the PR is
    # considered ready.
    #
    # Manual is blocking when +wait_for_reviews+ is on (the default); an
    # unsatisfied manual outcome holds the PR in its current phase until
    # the reviewer signs off.
    class Manual < Base
      TRIGGER_TYPE = "manual_review_pending"

      def kind = :human

      def blocking_by_default?
        config.wait_for_reviews?
      end

      def evaluate
        pending = signals.trigger(TRIGGER_TYPE)
        if pending
          return outcome_pending(
            blocking: blocking_by_default?,
            message: "manual review pending",
            metadata: { reviewer_login: pending[:reviewer_login] }.compact
          )
        end

        return outcome_not_applicable unless config.method_enabled?(:manual)

        outcome_satisfied
      end

      def decision
        reviewer_login = pending_reviewer_login
        return nil if reviewer_login.blank?

        Automation::Decision.request_review(
          pr_number: signals.pr_number,
          reviewers: [ reviewer_login ]
        )
      end

      private

      def pending_reviewer_login
        signals.trigger(TRIGGER_TYPE)&.dig(:reviewer_login)
      end
    end
  end
end
