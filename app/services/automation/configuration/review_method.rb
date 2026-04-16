# frozen_string_literal: true

module Automation
  module Configuration
    # A single review method configuration (copilot / paid_agent / codex /
    # ci_action / manual). Wraps the nested +review_settings.methods.<name>+
    # hash with a normalized interface so call sites do not have to reach
    # into raw +dig(...)+ chains.
    class ReviewMethod < ::Data.define(
      :name,
      :enabled,
      :action_name,
      :reviewer_login,
      :termination
    )
      NAMES = %i[copilot paid_agent codex ci_action manual].freeze

      class << self
        def from_hash(name, hash)
          hash ||= {}
          new(
            name: name.to_sym,
            enabled: hash["enabled"] == true,
            action_name: presence_or_nil(hash["action_name"]),
            reviewer_login: presence_or_nil(hash["reviewer_login"]),
            termination: Termination.from_hash(hash["termination"])
          )
        end

        private

        def presence_or_nil(value)
          return nil if value.nil?

          str = value.to_s
          str.strip.empty? ? nil : str
        end
      end

      def enabled? = enabled == true

      def max_review_rounds
        termination.max_review_rounds
      end

      def max_review_goal_retries
        termination.max_review_goal_retries
      end

      def timeout_minutes
        termination.timeout_minutes
      end

      def stop_when_no_comments?
        termination.stop_when_no_comments == true
      end
    end
  end
end
