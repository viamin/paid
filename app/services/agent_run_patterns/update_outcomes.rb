# frozen_string_literal: true

module AgentRunPatterns
  class UpdateOutcomes
    def self.call(...)
      new(...).call
    end

    def initialize(account:, patterns:)
      @account = account
      @patterns = patterns
    end

    def call
      account.remediation_decisions.pending_outcome.find_each do |decision|
        post_count = pattern_counts.fetch(decision.fingerprint, 0)

        decision.update!(
          post_remediation_failure_count: post_count,
          outcome: outcome_for(decision, post_count)
        )
      end
    end

    private

    attr_reader :account, :patterns

    def pattern_counts
      @pattern_counts ||= patterns.each_with_object({}) do |pattern, result|
        result[pattern.details[:fingerprint].to_s] = failure_count(pattern)
      end
    end

    def failure_count(pattern)
      pattern.details[:streak_length] ||
        pattern.details[:failure_count] ||
        pattern.details[:occurrence_count] ||
        0
    end

    def outcome_for(decision, post_count)
      return "regressed" if post_count > decision.pre_remediation_failure_count.to_i
      return "unchanged" if post_count >= decision.pre_remediation_failure_count.to_i

      "improved"
    end
  end
end
