# frozen_string_literal: true

module AgentRunPatterns
  # @spec RUN-OBSTACLE-005
  class UpdateOutcomes
    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
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

    attr_reader :account

    def post_remediation_counts(decision)
      return legacy_post_remediation_counts(decision) if decision.proposal_context["goal"].blank?
      return [ 0, 0 ] if decision.applied_at.blank?

      scope = AgentRun.joins(:project)
        .where(projects: { account_id: account.id })
        .where(goal: decision.proposal_context["goal"])
        .where(status: AgentRunPatterns::Detect::DETECTION_FINISHED_STATUSES)
        .where(completed_at: decision.applied_at..window_end(decision))

      [ failure_count(scope, decision), scope.count ]
    end

    def legacy_post_remediation_counts(decision)
      count = legacy_pattern_counts.fetch(decision.fingerprint, 0)
      [ count, count ]
    end

    def legacy_pattern_counts
      @legacy_pattern_counts ||= AgentRunPatterns::Detect.call(account: account).each_with_object({}) do |pattern, counts|
        counts[pattern.details[:fingerprint].to_s] = pattern_failure_count(pattern)
      end
    end

    def pattern_failure_count(pattern)
      pattern.details[:streak_length] ||
        pattern.details[:failure_count] ||
        pattern.details[:occurrence_count] ||
        0
    end

    def failure_count(scope, decision)
      pattern_type = decision.proposal_context["pattern_type"]
      return streak_failure_count(scope) if pattern_type == "failure_streak"

      failures = scope.where(status: AgentRun::FAILURE_STATUSES)
      return failures.count unless pattern_type == "error_cluster"

      failures.count { |run| matching_error_pattern?(run, decision) }
    end

    # Mirrors AgentRunPatterns::Detect#detect_failure_streak: count only the
    # consecutive failures immediately following remediation, stopping at the
    # first success. A later, unrelated failure run must not be conflated with
    # a streak that the fix already broke.
    def streak_failure_count(scope)
      scope.order(completed_at: :asc, id: :asc)
        .pluck(:status)
        .take_while { |status| AgentRun::FAILURE_STATUSES.include?(status) }
        .size
    end

    def matching_error_pattern?(run, decision)
      error_pattern = decision.proposal_context["error_pattern"]
      return true if error_pattern.blank?

      AgentRunPatterns::Detect.normalize_error(run.error_message.to_s) == error_pattern
    end

    def window_end(decision)
      decision.applied_at + window_hours(decision).hours
    end

    def window_hours(decision)
      hours = decision.proposal_context.fetch("window_hours", AgentRunPatterns::Detect::DEFAULT_WINDOW_HOURS).to_i
      hours.positive? ? hours : AgentRunPatterns::Detect::DEFAULT_WINDOW_HOURS
    end

    def outcome_for(decision, post_count, post_exposure)
      return "insufficient_evidence" unless comparable_exposure?(decision, post_exposure)
      return "regressed" if post_count > decision.pre_remediation_failure_count.to_i
      return "unchanged" if post_count >= decision.pre_remediation_failure_count.to_i

      "improved"
    end

    def comparable_exposure?(decision, post_exposure)
      return true if decision.proposal_context["goal"].blank?

      baseline = decision.pre_remediation_exposure_count.to_i
      baseline.positive? && post_exposure >= baseline
    end
  end
end
