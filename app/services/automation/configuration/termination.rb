# frozen_string_literal: true

module Automation
  module Configuration
    # Termination conditions for a review method: how many rounds to allow,
    # whether to stop when reviewers post no comments, an optional quality
    # threshold, a wall-clock timeout, and an optional per-provider token
    # budget that fallback callers can use to cap context size when handing
    # the review off to a different provider.
    #
    # Only +paid_agent+ uses +max_review_goal_retries+; it is nil for every
    # other method.
    #
    # Construct from the nested Hash returned by
    # +Project#review_method_config+:
    #
    #   Termination.from_hash(config.dig("termination"))
    class Termination < ::Data.define(
      :max_review_rounds,
      :max_review_goal_retries,
      :stop_when_no_comments,
      :quality_threshold,
      :timeout_minutes,
      :token_budget
    )
      EMPTY = new(
        max_review_rounds: nil,
        max_review_goal_retries: nil,
        stop_when_no_comments: false,
        quality_threshold: nil,
        timeout_minutes: nil,
        token_budget: nil
      ).freeze

      def self.from_hash(hash)
        return EMPTY if hash.nil? || hash.empty?

        new(
          max_review_rounds: integer_or_nil(hash["max_review_rounds"]),
          max_review_goal_retries: integer_or_nil(hash["max_review_goal_retries"]),
          stop_when_no_comments: hash["stop_when_no_comments"] == true,
          quality_threshold: presence_or_nil(hash["quality_threshold"]),
          timeout_minutes: integer_or_nil(hash["timeout_minutes"]),
          token_budget: integer_or_nil(hash["token_budget"])
        )
      end

      def self.integer_or_nil(value)
        return nil if value.nil?
        return value if value.is_a?(Integer)

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
      private_class_method :integer_or_nil

      def self.presence_or_nil(value)
        return nil if value.nil?

        str = value.to_s
        str.strip.empty? ? nil : str
      end
      private_class_method :presence_or_nil
    end
  end
end
