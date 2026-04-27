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
        :draft_review_limit_reached,
        :consecutive_draft_failures_breaker,
        :review_goal_retry_limit_requires_escalation,
        :followup_limit_reached,
        :escalation_dismissed,
        :owner_reviewer_login,
        :escalation_reason,
        :draft,
        :scan
      )
        PHASES = %w[draft ready escalated restarted].freeze

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
              draft_review_limit_reached: lifecycle[:draft_review_limit_reached] == true,
              consecutive_draft_failures_breaker: lifecycle[:consecutive_draft_failures_breaker] == true,
              review_goal_retry_limit_requires_escalation: lifecycle[:review_goal_retry_limit_requires_escalation] == true,
              followup_limit_reached: lifecycle[:followup_limit_reached] == true,
              escalation_dismissed: lifecycle[:escalation_dismissed] == true,
              owner_reviewer_login: lifecycle[:owner_reviewer_login],
              escalation_reason: lifecycle[:escalation_reason],
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
