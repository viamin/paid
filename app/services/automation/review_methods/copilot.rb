# frozen_string_literal: true

module Automation
  module ReviewMethods
    # GitHub Copilot review — requested via GraphQL review-request on the PR.
    # Copilot auto-reviews draft PRs once assigned and posts inline review
    # threads.
    #
    # Copilot's pending outcome is a non-blocking sidecar: the PR continues
    # along the normal follow-up path, and the strategy simply emits a
    # +request_review+ decision so the bot gets assigned.
    class Copilot < Base
      BOT_LOGIN = "copilot"
      TRIGGER_TYPE = "review_bot_review_pending"

      def kind = :bot

      def evaluate
        pending = matching_trigger
        if pending
          return outcome_pending(
            blocking: false,
            message: "copilot review requested",
            metadata: { reviewer_login: BOT_LOGIN }
          )
        end

        return outcome_not_applicable unless config.method_enabled?(:copilot)

        outcome_satisfied
      end

      # Emits a request_review decision whenever the scan surfaces a
      # review_bot_review_pending trigger addressed to the copilot login.
      # When the trigger carries a +request_logins+ fallback chain, the
      # full chain is forwarded so RequestReviewActivity can attempt
      # secondaries on 422 errors.
      def decision
        trigger = matching_trigger
        return nil unless trigger

        Automation::Decision.request_review(
          pr_number: signals.pr_number,
          reviewers: review_bot_reviewers_from(trigger)
        )
      end

      private

      def matching_trigger
        trigger = signals.trigger(TRIGGER_TYPE)
        return nil if trigger.nil?
        return nil unless trigger[:request_login].to_s.casecmp(BOT_LOGIN).zero?

        trigger
      end
    end
  end
end
