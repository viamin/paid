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
        :failure_streak_limit_reached,
        :escalation_dismissed,
        :owner_reviewer_login,
        :escalation_reason,
        :consecutive_unsuccessful_automatic_runs,
        :consecutive_operational_failures,
        :last_meaningful_progress_at,
        :draft_review_count,
        :review_goal_retry_count,
        :pr_followup_count,
        :draft,
        :scan
      )
        class << self
          def from_metadata(metadata)
            return nil unless metadata

            lifecycle = metadata[:lifecycle]
            return nil unless lifecycle

            new(
              issue_id: lifecycle[:issue_id],
              pr_number: lifecycle[:pr_number],
              phase: lifecycle[:phase]&.to_s,
              active_run_exists: lifecycle[:active_run_exists] == true,
              operational_failure_breaker: lifecycle[:operational_failure_breaker] == true,
              failure_streak_limit_reached: lifecycle[:failure_streak_limit_reached] == true,
              escalation_dismissed: lifecycle[:escalation_dismissed] == true,
              owner_reviewer_login: lifecycle[:owner_reviewer_login],
              escalation_reason: lifecycle[:escalation_reason],
              consecutive_unsuccessful_automatic_runs: lifecycle[:consecutive_unsuccessful_automatic_runs].to_i,
              consecutive_operational_failures: lifecycle[:consecutive_operational_failures].to_i,
              last_meaningful_progress_at: lifecycle[:last_meaningful_progress_at],
              draft_review_count: lifecycle[:draft_review_count].to_i,
              review_goal_retry_count: lifecycle[:review_goal_retry_count].to_i,
              pr_followup_count: lifecycle[:pr_followup_count].to_i,
              draft: lifecycle[:draft] == true,
              scan: metadata[:scan]
            )
          end
        end

        def draft_phase? = phase == "draft" || phase == "restarted"
        def ready_phase? = phase == "ready"
        def escalated_phase? = phase == "escalated"
      end
    end
  end
end
