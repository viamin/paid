# frozen_string_literal: true

module ProjectDelegation
  # @spec PROJECT-DELEGATION-007
  class ExpansionGuard
    MAX_PILOT_PROJECTS = 5
    Decision = Data.define(:permitted, :reason, :metrics) do
      def permitted? = permitted
      def blocked? = !permitted
    end

    def self.call(project:) = new(project:).call

    def initialize(project:)
      @project = project
    end

    def call
      metrics = PilotMetrics.call(project:)
      reasons = rollout_reasons + pilot_limit_reasons + threshold_reasons(metrics)
      Decision.new(permitted: reasons.empty?, reason: reasons, metrics: metrics)
    end

    private

    attr_reader :project

    def pilot_limit_reasons
      return [] if pilot_project_ids.include?(project.id)
      return [] if pilot_project_ids.size < MAX_PILOT_PROJECTS

      [ "pilot_project_limit" ]
    end

    def pilot_project_ids
      @pilot_project_ids ||= ProjectDelegationMetric.where(cohort: "pilot").distinct.pluck(:project_id)
    end

    def rollout_reasons
      reasons = []
      reasons << "automation_phases_disabled" unless FeatureFlags.enabled?(:automation_phases, project:)
      reasons << "project_delegation_disabled" unless FeatureFlags.enabled?(:project_delegation, project:)
      reasons
    end

    def threshold_reasons(metrics)
      return [ "pilot_threshold_not_met" ] if metrics.threshold_met? == false && metrics.pause_reasons.empty?

      metrics.pause_reasons + missing_threshold_reasons(metrics)
    end

    def missing_threshold_reasons(metrics)
      reasons = []
      reasons << "minimum_completed_issues" if metrics.completed_issues < PilotMetrics::MIN_COMPLETED_ISSUES
      reasons << "minimum_pilot_days" if metrics.window_days < PilotMetrics::MIN_PILOT_DAYS
      reasons << "missing_baseline" if metrics.baseline.nil?
      reasons << "missing_evidence" unless metrics.evidence_complete?
      reasons
    end
  end
end
