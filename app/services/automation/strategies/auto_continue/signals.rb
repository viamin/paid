# frozen_string_literal: true

module Automation
  module Strategies
    class AutoContinue
      # Immutable input for {Strategies::AutoContinue}. Captures the
      # lifecycle gating state of a PR — circuit breakers, counter limits,
      # phase flags — so that the strategy can make phase-progression
      # decisions without performing I/O.
      #
      # Signals are built by the scan activity after querying run history,
      # issue counters, and project configuration. The strategy consumes
      # them as pure data to decide whether to escalate, dismiss, skip, or
      # delegate to {Strategies::AutoReview} for scan-based decisions.
      class Signals < ::Data.define(
        :issue_id,
        :pr_number,
        :phase,
        :active_run_exists,
        :operational_failure_breaker,
        :no_progress_stuck,
        :failure_streak_limit_reached,
        :review_goal_retry_limit_requires_escalation,
        :owner_reviewer_login,
        :escalation_reason,
        :escalation_reason_key,
        :consecutive_unsuccessful_automatic_runs,
        :consecutive_operational_failures,
        :last_meaningful_progress_at,
        :draft,
        :scan
      )
        class << self
          def from_metadata(metadata)
            return nil unless metadata

            lifecycle = value_for(metadata, :lifecycle)
            return nil unless lifecycle

            new(
              issue_id: value_for(lifecycle, :issue_id),
              pr_number: value_for(lifecycle, :pr_number),
              phase: value_for(lifecycle, :phase)&.to_s,
              active_run_exists: value_for(lifecycle, :active_run_exists) == true,
              operational_failure_breaker: value_for(lifecycle, :operational_failure_breaker) == true,
              no_progress_stuck: value_for(lifecycle, :no_progress_stuck) == true,
              failure_streak_limit_reached: value_for(lifecycle, :failure_streak_limit_reached) == true,
              review_goal_retry_limit_requires_escalation: value_for(lifecycle, :review_goal_retry_limit_requires_escalation) == true,
              owner_reviewer_login: value_for(lifecycle, :owner_reviewer_login),
              escalation_reason: value_for(lifecycle, :escalation_reason),
              escalation_reason_key: value_for(lifecycle, :escalation_reason_key),
              consecutive_unsuccessful_automatic_runs: value_for(lifecycle, :consecutive_unsuccessful_automatic_runs).to_i,
              consecutive_operational_failures: value_for(lifecycle, :consecutive_operational_failures).to_i,
              last_meaningful_progress_at: value_for(lifecycle, :last_meaningful_progress_at),
              draft: value_for(lifecycle, :draft) == true,
              scan: value_for(metadata, :scan)
            )
          end

          private

          def value_for(hash, key)
            hash[key] || hash[key.to_s]
          end
        end

        def draft_phase? = phase == "draft" || phase == "restarted"
        def ready_phase? = phase == "ready"
        def escalated_phase? = phase == "escalated"
      end
    end
  end
end
