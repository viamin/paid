# frozen_string_literal: true

module ProjectDelegation
  # Fail-closed evaluation of whether RDR-080 delegation may broaden for a
  # project. Broadening stays disabled unless both rollout guards permit and
  # the recorded pilot evidence meets every threshold versus the project's own
  # conservative baseline. Missing or incomplete evidence blocks with its own
  # reason; it never counts as passing. An unresolved expansion pause blocks
  # broadening and returns the project's effective posture to `conservative`.
  #
  # @spec PROJECT-DELEGATION-007
  class ExpansionGuard
    MIN_COMPLETED_ISSUES = 30
    MIN_WINDOW_DAYS = 14
    MIN_DECISION_VOLUME_REDUCTION = 0.25
    MAX_COMPLETION_RATE_DECLINE = 0.05

    Result = Data.define(:allowed, :reasons, :pilot, :baseline, :pause) do
      def allowed? = allowed
      def blocked? = !allowed
    end

    class << self
      def call(project:)
        pilot = PilotMetric.latest_for(project, "bounded_delivery")
        baseline = PilotMetric.latest_for(project, "conservative")
        pause = ExpansionPause.unresolved_for(project).first
        reasons = failed_checks(project:, pilot:, baseline:, pause:)
        Result.new(allowed: reasons.empty?, reasons:, pilot:, baseline:, pause:)
      end

      def paused?(project)
        ExpansionPause.unresolved_for(project).exists?
      end

      # The posture every surface must treat as effective: `conservative`
      # while paused, before both rollout guards permit, or before the project
      # is enrolled in the pilot; `bounded_delivery` only otherwise.
      def effective_posture(project)
        return "conservative" if paused?(project)
        return "conservative" unless guards_permit?(project)
        return "conservative" unless PilotMetric.where(project:, posture: "bounded_delivery").exists?

        "bounded_delivery"
      end

      private

      def failed_checks(project:, pilot:, baseline:, pause:)
        reasons = []
        reasons << :rollout_guard_disabled unless guards_permit?(project)
        reasons << :expansion_paused if pause.present?
        reasons << :missing_pilot_metrics if pilot.nil?
        reasons << :missing_baseline_metrics if baseline.nil?
        return reasons if pilot.nil? || baseline.nil?

        unless complete_evidence?(pilot, baseline)
          reasons << :missing_evidence
          return reasons
        end

        reasons << :insufficient_completed_issues if pilot.completed_issues < MIN_COMPLETED_ISSUES
        reasons << :insufficient_review_window if window_days(pilot) < MIN_WINDOW_DAYS
        reasons << :decision_volume_not_reduced unless decision_volume_reduced?(pilot, baseline)
        reasons << :median_decision_time_increased if pilot.median_decision_seconds > baseline.median_decision_seconds
        reasons << :completion_rate_declined if completion_decline(pilot, baseline) > MAX_COMPLETION_RATE_DECLINE
        reasons << :material_reversal_attributable if pilot.material_attributable_reversals.any?
        reasons
      end

      def guards_permit?(project)
        Automation::RolloutGuard.enabled?(project) && FeatureFlags.enabled?(:project_delegation, project:)
      end

      # Every comparison the thresholds rely on must exist on both rows;
      # a missing aggregate is missing evidence, not a pass.
      def complete_evidence?(pilot, baseline)
        pilot.median_decision_seconds.present? && baseline.median_decision_seconds.present? &&
          pilot.completion_rate.present? && baseline.completion_rate.present? &&
          pilot.decisions_per_completed_issue.present? && baseline.decisions_per_completed_issue.present?
      end

      def window_days(metric)
        (metric.window_ended_at - metric.window_started_at).to_f / 86_400
      end

      def decision_volume_reduced?(pilot, baseline)
        reduction = baseline.decisions_per_completed_issue - pilot.decisions_per_completed_issue
        reduction / baseline.decisions_per_completed_issue >= MIN_DECISION_VOLUME_REDUCTION
      end

      def completion_decline(pilot, baseline)
        baseline.completion_rate.to_d - pilot.completion_rate.to_d
      end
    end
  end
end
