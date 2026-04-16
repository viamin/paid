# frozen_string_literal: true

module Automation
  module ReviewMethods
    # ChatGPT Codex Connector review — body-only bot triggered by
    # @-mention comment (codex does NOT auto-review drafts like copilot
    # does). Paid mentions the bot via RequestReviewActivity; codex then
    # posts a review body rather than inline threads.
    #
    # Like copilot, codex's pending outcome is a non-blocking sidecar.
    class Codex < Base
      BOT_LOGIN = "chatgpt-codex-connector"
      TRIGGER_TYPE = "review_bot_review_pending"

      def kind = :comment_bot

      def evaluate
        pending = matching_trigger
        if pending
          return outcome_pending(
            blocking: false,
            message: "codex review requested",
            metadata: { reviewer_login: BOT_LOGIN }
          )
        end

        return outcome_not_applicable unless config.method_enabled?(:codex)

        outcome_satisfied
      end

      def decision
        trigger = matching_trigger
        return nil if trigger.nil?
        return nil unless trigger[:request_login].to_s.casecmp(BOT_LOGIN).zero?

        Automation::Decision.request_review(
          pr_number: signals.pr_number,
          reviewers: [ BOT_LOGIN ]
        )
      end

      private

      def matching_trigger
        signals.trigger(TRIGGER_TYPE)
      end
    end
  end
end
