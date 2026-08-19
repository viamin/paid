# frozen_string_literal: true

module Automation
  module Strategies
    # Auto-continue strategy — owns the policy for PR lifecycle
    # progression decisions. Given lifecycle gating signals (circuit
    # breakers, counter limits, phase state) and an optional scan
    # payload, it decides whether to escalate, dismiss, skip, or
    # delegate to {Strategies::AutoReview} for scan-based follow-up.
    #
    # == Responsibilities
    #
    # * Enforce lifecycle gates: active-run dedup, operational-failure
    #   breaker, draft-review limit, consecutive-draft-failures breaker,
    #   review-goal retry limit, followup limit.
    # * Handle phase-level transitions: escalation, dismissal.
    # * Delegate to {Strategies::AutoReview} when gates pass and a scan
    #   payload is available.
    #
    # == Boundaries
    #
    # * *State gathering* (I/O) lives in the scan activity, which builds
    #   the lifecycle signals hash and scan payload.
    # * *Policy evaluation* (this class) is pure — no I/O, no side
    #   effects.
    # * *Action execution* lives in the workflow, which consumes the
    #   returned {Automation::Result} decisions.
    #
    # == Metadata contract
    #
    # The strategy reads two keys from {Automation::Context#metadata}:
    #
    # * +:lifecycle+ — a Hash of gating signals built by the scan
    #   activity (see {AutoContinue::Signals.from_metadata}).
    # * +:scan+ — the trigger payload from phase-specific scanning,
    #   forwarded to {Strategies::AutoReview} when gates pass.
    #
    # When +:lifecycle+ is absent the strategy falls back to delegating
    # directly to {Strategies::AutoReview} with the +:scan+ key, so
    # existing callers that only pass scan data continue to work.
    class AutoContinue
      include Automation::Strategy

      REVIEW_RUN_TRIGGER_TYPES = %w[
        paid_agent_review_pending
        review_goal_retry
      ].freeze

      # @param context [Automation::Context]
      # @return [Automation::Result]
      def evaluate(context)
        signals = Signals.from_metadata(context.metadata)

        # When lifecycle signals are absent, fall back to AutoReview
        # for backwards compatibility with callers that only pass scan
        # data (e.g. specs exercising AutoReview in isolation).
        return delegate_to_auto_review(context) unless signals

        # An escalated PR is already held for the owner. The scan reports only
        # recovery for it (dismissal, owner approval), so with no scan signal
        # there is nothing left to decide — and re-escalating would re-run
        # MarkEscalatedActivity, re-posting the escalation comment on the PR
        # every poll cycle. This gate is unreachable before the escalated phase
        # became the hold, because escalated PRs were excluded from the scan.
        # @spec PR-ESCALATION-001
        return noop_result if signals.escalated_phase? && scan_trigger_types(signals).empty?

        # Token-cap escalation is a hard spend fuse. It must outrank the active
        # run gate so stale queued runs cannot hide an already-over-budget PR.
        return escalate_result(signals) if signals.pr_auto_continue_token_limit_reached

        # Gate: active run — no decisions while an agent is running.
        return noop_result if signals.active_run_exists

        # Gate: lifecycle breakers and limits.
        gate_result = check_lifecycle_gates(context:, signals:)
        return gate_result if gate_result

        # No gate tripped — delegate to AutoReview for scan-based
        # decisions (follow-up runs, review requests, ready/merge).
        return noop_result if signals.scan.nil?

        review_context = context.with_metadata(scan: signals.scan)
        auto_review_strategy(context).evaluate(review_context)
      end

      private

      def check_lifecycle_gates(context:, signals:)
        # The scan already decided to dismiss escalation this cycle (the owner
        # removed paid-escalated). The dismissal has not executed yet, so the
        # gates below still see the pre-clearing counters and would re-escalate
        # on this same tick, re-adding the label the owner just removed. Let the
        # dismissal through; a still-stuck PR surfaces again on a later scan
        # once it has re-entered a gated phase.
        return nil if dismiss_escalation_pending?(signals)

        # Operational failure breaker — provider/infrastructure bursts only
        # escalate once the PR has also gone stale without meaningful
        # progress for too long.
        if signals.operational_failure_breaker
          return escalation_service_result(
            signals,
            evaluate_escalation(context:, signals:)
          )
        end

        if (service_result = evaluate_escalation(context:, signals:))
          return escalation_service_result(signals, service_result)
        end

        nil
      end

      def evaluate_escalation(context:, signals:)
        return unless escalation_candidate?(signals)

        Coordination::EscalationService.call(
          project: context.project,
          issue: context.record,
          signals: signals
        )
      end

      def escalation_candidate?(signals)
        return true if signals.operational_failure_breaker
        return false unless signals.no_progress_stuck
        return true if signals.review_goal_retry_limit_requires_escalation
        return false unless signals.failure_streak_limit_reached
        return false if review_run_pending?(signals) # @spec FOCUSED-RUN-006

        true
      end

      def review_run_pending?(signals)
        scan_trigger_types(signals).any? { |type| REVIEW_RUN_TRIGGER_TYPES.include?(type) }
      end

      def dismiss_escalation_pending?(signals)
        scan_trigger_types(signals).include?("dismiss_escalation")
      end

      def scan_trigger_types(signals)
        Array(signals.scan&.dig(:triggers) || signals.scan&.dig("triggers")).map { |trigger| trigger_type(trigger) }
      end

      def trigger_type(trigger)
        return unless trigger.is_a?(Hash)

        trigger[:type] || trigger["type"]
      end

      def escalation_service_result(signals, service_result)
        return escalate_result(signals, reason: service_result.reason) if service_result.escalate?
        return nil if service_result.auto_resolve?

        noop_result
      end

      def escalate_result(signals, reason: signals.escalation_reason)
        Result.new(decisions: [
          Decision.escalate(
            issue_id: signals.issue_id,
            pr_number: signals.pr_number,
            owner_reviewer_login: signals.owner_reviewer_login,
            reason: reason,
            reason_key: signals.escalation_reason_key
          )
        ])
      end
      def delegate_to_auto_review(context)
        auto_review_strategy(context).evaluate(context)
      end

      def auto_review_strategy(context)
        Strategies::Select.call(
          strategy_type: :auto_review,
          project: context.project
        )
      end
    end
  end
end
