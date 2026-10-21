# frozen_string_literal: true

module AgentRunPatterns
  # @spec RUN-OBSTACLE-005
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
        post_count, post_exposure = post_remediation_counts(decision)

        decision.update!(
          post_remediation_failure_count: post_count,
          post_remediation_exposure_count: post_exposure,
          outcome: outcome_for(decision, post_count, post_exposure)
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

    def post_remediation_counts(decision)
      scope = AgentRun.joins(:project)
        .where(projects: { account_id: account.id })
        .where(goal: decision.proposal_context["goal"])
        .where(completed_at: decision.applied_at..)

      [ scope.where(status: AgentRun::FAILURE_STATUSES).count, scope.count ]
    end

    def outcome_for(decision, post_count, post_exposure)
      return "insufficient_evidence" unless comparable_exposure?(decision, post_exposure)
      return "regressed" if post_count > decision.pre_remediation_failure_count.to_i
      return "unchanged" if post_count >= decision.pre_remediation_failure_count.to_i

      "improved"
    end

    def comparable_exposure?(decision, post_exposure)
      baseline = decision.pre_remediation_exposure_count.to_i
      baseline.positive? && post_exposure >= baseline
    end
  end
end
