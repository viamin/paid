# frozen_string_literal: true

module Automation
  module Configuration
    # Auto-review automation configuration for a project. Wraps
    # {ReviewSettings} and encodes the provider-selection and ordering
    # rules that previously lived as conditionals in
    # +Project#review_bot_request_login+ and various activities.
    #
    # Callers should ask the config object for the strategy-level answers
    # they need (e.g. "which bot should we request?", "what's the ordered
    # list of enabled methods?") rather than branching on raw method flags.
    class AutoReview < ::Data.define(:review_settings)
      # Canonical ordering for enabled review methods. Matches the legacy
      # +Project::REVIEW_METHODS+ order so views and intersection callers
      # observe the same sequence after the normalization refactor.
      METHOD_ORDER = ReviewMethod::NAMES

      # Priority order used by {#bot_request_login}: the first bot-backed
      # method that is enabled wins. Copilot takes precedence over codex
      # because codex does not auto-review draft PRs and requires an
      # explicit @-mention (see +Activities::RequestReviewActivity+).
      BOT_REQUEST_PRIORITY = %i[copilot codex].freeze

      # Maps each bot-backed review method to its canonical GitHub login.
      # Defined here (rather than reached out of
      # +Activities::RequestReviewActivity+) so that the config object is
      # the single source of truth for provider-selection rules.
      BOT_REVIEWER_LOGINS = {
        copilot: "copilot",
        codex: "chatgpt-codex-connector"
      }.freeze

      def self.from_project(project)
        new(review_settings: ReviewSettings.from_project(project))
      end

      def enabled? = review_settings.enabled?
      def wait_for_reviews? = review_settings.wait_for_reviews?
      def address_all_bot_reviews? = review_settings.address_all_bot_reviews?

      def method_for(name)
        review_settings.method_for(name)
      end

      def method_enabled?(name)
        review_settings.method_enabled?(name)
      end

      # Returns the enabled review methods as {ReviewMethod} objects in
      # {METHOD_ORDER}. Unlike {#bot_request_login}, this helper does NOT
      # gate on +review_settings.enabled?+ — callers that need the global
      # review toggle honoured (e.g. scan decision logic) should consult
      # {#enabled?} separately. This mirrors the legacy semantics of
      # +Project#enabled_review_methods+, which returns per-method flags
      # regardless of the top-level toggle.
      def ordered_enabled_methods
        METHOD_ORDER.filter_map { |name| method_for(name) if method_enabled?(name) }
      end

      # Returns the GitHub login Paid should request as the automated
      # reviewer, or nil when no bot-backed method is enabled. Preserves
      # the legacy precedence rule (copilot before codex) and the safety
      # rule that a globally-disabled review toggle short-circuits the
      # lookup regardless of per-method flags.
      def bot_request_login
        bot_request_chain.first
      end

      # Returns the ordered list of bot-backed reviewer logins to try when
      # requesting an automated review, with the primary provider first.
      # Used by +Activities::RequestReviewActivity+ to attempt fallback
      # reviewers when the primary bot is unavailable (e.g. Copilot
      # rate-limited or not enabled on the repo).
      #
      # Honors the global review toggle: returns +[]+ when reviews are
      # disabled regardless of per-method flags.
      def bot_request_chain
        return [] unless enabled?
        BOT_REQUEST_PRIORITY.filter_map do |name|
          BOT_REVIEWER_LOGINS.fetch(name) if method_enabled?(name)
        end
      end

      # True when +paid_agent+ is the only enabled review method. Used by
      # scan code that has to distinguish "paid_agent review only" from
      # "paid_agent plus other methods" when deciding how to gate PR
      # phases. Gated on {#enabled?} because a globally-disabled review
      # toggle means no review method is effectively active.
      def paid_agent_sole_method?
        return false unless enabled?

        review_settings.enabled_method_names == [ :paid_agent ]
      end
    end
  end
end
