# frozen_string_literal: true

module Automation
  # Shared parser for review-bot trigger payloads. Included by both the
  # evaluator (scan path) and the poll workflow (polling path) so the
  # trigger schema has a single source of truth.
  module ReviewBotTrigger
    private

    # Extracts the ordered list of reviewer logins from a review-bot
    # trigger. Prefers the +request_logins+ array (post-fallback-chain
    # support) and falls back to the legacy single +request_login+ field
    # so in-flight workflow histories that pre-date the chain encoding
    # still produce the same single-bot activity invocation on replay.
    def review_bot_reviewers_from(trigger) # @spec QUALITY-LOOPS-006
      return [] unless trigger

      chain = trigger[:request_logins]
      return Array(chain).compact if chain.is_a?(Array) && chain.any?

      login = trigger[:request_login]
      login.present? ? [ login ] : []
    end
  end
end
