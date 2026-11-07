# frozen_string_literal: true

module ProjectDelegation
  # The one decision service for broadening delegated delivery past the
  # `conservative` default (RDR-080 rollout guard and pilot thresholds).
  # Broadening is disabled by default and requires: both rollout guards, an
  # active enrollment, complete baseline and pilot metric evidence, at least
  # 30 completed issues and 14 days in the pilot, at least a 25% reduction in
  # Inbox decisions per completed issue versus the project's own baseline, no
  # median-decision-time increase, at most a 5 percentage-point completion-rate
  # decline, and no reversal attributable to delegated work. A material
  # reversal or missing evidence returns `pause_reason` so the caller parks
  # the affected project pending human review.
  #
  # @spec PROJECT-DELEGATION-007
  class ExpansionGuard
    MIN_COMPLETED_ISSUES = 30
    MIN_REVIEW_DAYS = 14
    MIN_DECISION_REDUCTION = 0.25
    MAX_COMPLETION_RATE_DECLINE = 0.05

    MISSING_EVIDENCE = "missing_evidence"
    MATERIAL_REVERSAL = "material_reversal"

    # The metric keys every recorded snapshot must carry. A value may be nil
    # when its population was empty (a young pilot); a missing key means the
    # evidence itself was not produced.
    REQUIRED_METRIC_KEYS = %w[
      inbox_decisions completed_issues decisions_per_completed_issue
      median_decision_seconds admitted_issues completed_issue_rate
      delegated_reversal_count
    ].freeze

    Result = Data.define(:permitted, :reasons, :pause_reason, :baseline, :pilot) do
      def permitted? = permitted
      def blocked? = !permitted
    end

    def self.call(project:)
      new(project:).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      return blocked(%i[broadening_disabled_by_default]) unless enrollment
      return blocked(%i[project_delegation_disabled]) unless FeatureFlags.enabled?(:project_delegation, project:)
      return blocked(%i[automation_phases_disabled]) unless Automation::RolloutGuard.enabled?(project)
      return Result.new(permitted: false, reasons: %i[expansion_paused],
        pause_reason: enrollment.pause_reason, baseline: nil, pilot: nil) if enrollment.paused?

      baseline = enrollment.latest_snapshot("conservative_baseline")
      pilot = enrollment.latest_snapshot("bounded_delivery")
      pause = pause_condition(baseline, pilot)
      return paused(pause, baseline, pilot) if pause

      reasons = unmet_thresholds(baseline, pilot)
      Result.new(permitted: reasons.empty?, reasons: reasons, pause_reason: nil, baseline:, pilot:)
    end

    private

    attr_reader :project

    def enrollment
      @enrollment ||= project.delegation_pilot_enrollments.order(id: :desc).first
    end

    def blocked(reasons)
      Result.new(permitted: false, reasons: reasons, pause_reason: nil, baseline: nil, pilot: nil)
    end

    def paused(reason, baseline, pilot)
      Result.new(permitted: false, reasons: [ reason.to_sym ], pause_reason: reason, baseline:, pilot:)
    end

    # Missing evidence is an inability to produce the comparison, not a young
    # pilot's thin data: absent or malformed snapshots, or a baseline with no
    # conservative population to compare against. A delegated reversal is
    # material on its own.
    def pause_condition(baseline, pilot)
      return MISSING_EVIDENCE if baseline.nil? || pilot.nil?
      return MISSING_EVIDENCE unless required_keys_present?(baseline) && required_keys_present?(pilot)
      return MISSING_EVIDENCE if baseline.metrics.fetch("completed_issues").to_i.zero? ||
        baseline.metrics.fetch("admitted_issues").to_i.zero?
      return MATERIAL_REVERSAL if pilot.metrics.fetch("delegated_reversal_count").to_i.positive?

      nil
    end

    def required_keys_present?(snapshot)
      (REQUIRED_METRIC_KEYS - snapshot.metrics.keys).empty?
    end

    def unmet_thresholds(baseline, pilot)
      reasons = []
      reasons << :insufficient_completed_issues unless pilot.metrics.fetch("completed_issues").to_i >= MIN_COMPLETED_ISSUES
      reasons << :review_window_too_short unless review_window_elapsed?
      reasons << :inbox_decision_reduction_unmet unless decision_reduction_met?(baseline, pilot)
      reasons << :median_decision_time_increased if median_decision_time_increased?(baseline, pilot)
      reasons << :completion_rate_decline_exceeded if completion_rate_decline_exceeded?(baseline, pilot)
      reasons
    end

    def review_window_elapsed?
      enrollment.enrolled_at <= MIN_REVIEW_DAYS.days.before(Time.current)
    end

    # At least a 25% reduction versus baseline. A pilot ratio that has not been
    # produced yet (no completed issues) or a baseline already at zero decisions
    # per completion cannot demonstrate the reduction and stays unmet.
    def decision_reduction_met?(baseline, pilot)
      baseline_value = baseline.metrics.fetch("decisions_per_completed_issue")
      pilot_value = pilot.metrics.fetch("decisions_per_completed_issue")
      return false if baseline_value.nil? || pilot_value.nil? || baseline_value.zero?

      pilot_value <= baseline_value * (1 - MIN_DECISION_REDUCTION)
    end

    def median_decision_time_increased?(baseline, pilot)
      baseline_value = baseline.metrics.fetch("median_decision_seconds")
      pilot_value = pilot.metrics.fetch("median_decision_seconds")
      return false if baseline_value.nil? || pilot_value.nil?

      pilot_value > baseline_value
    end

    def completion_rate_decline_exceeded?(baseline, pilot)
      baseline_value = baseline.metrics.fetch("completed_issue_rate")
      pilot_value = pilot.metrics.fetch("completed_issue_rate")
      return true if baseline_value.nil? || pilot_value.nil?

      (baseline_value - pilot_value) > MAX_COMPLETION_RATE_DECLINE
    end
  end
end
