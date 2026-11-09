# frozen_string_literal: true

module ProjectDelegation
  # RDR-080 promotion gate. It is deliberately separate from pilot opt-in:
  # pilot projects may be explicitly bounded, while defaults can never broaden
  # until this evidence-backed gate permits expansion.
  # @spec PROJECT-DELEGATION-007
  class ExpansionGuard
    CACHE_TTL = 20.seconds
    CACHE_PREFIX = "project_delegation/expansion_guard/v1"

    Result = Data.define(:allowed, :reason, :metrics) do
      def allowed? = allowed
      def paused? = !allowed && reason != "expansion_guard_disabled"
      def to_h = { allowed:, reason:, metrics: metrics&.to_h }
    end

    def self.call(project:, now: Time.current)
      return new(project:, metrics: nil).call unless FeatureFlags.enabled?(:project_delegation_expansion, project:)

      Rails.cache.fetch(cache_key(project, now), expires_in: CACHE_TTL) do
        new(project:, metrics: PilotMetrics.call(project:, now:)).call
      end
    end

    def self.cache_key(project, now)
      latest_event_id = InboxHistoryEvent.where(project:, source: "project_delegation_pilot").maximum(:id)
      posture_version = project.delegation_posture&.cache_key_with_version
      policy_signature = Posture.policy_signature(project)
      [ CACHE_PREFIX, project.id, posture_version, policy_signature, latest_event_id, now.to_i / CACHE_TTL.to_i ].compact
    end

    def initialize(project:, metrics:)
      @project = project
      @metrics = metrics
    end

    def call
      return Result.new(allowed: false, reason: "expansion_guard_disabled", metrics:) unless FeatureFlags.enabled?(:project_delegation_expansion, project:)
      return Result.new(allowed: false, reason: "missing_evidence", metrics:) unless metrics.available?

      values = metrics.metrics
      return blocked(values, "material_reversal") if values[:material_reversals].positive?
      return blocked(values, "security_breach") if values[:security_breaches].positive?
      return blocked(values, "tenant_breach") if values[:tenant_breaches].positive?
      return blocked(values, "trust_breach") if values[:trust_breaches].positive?
      return blocked(values, "missing_evidence") if values[:missing_evidence].positive?

      baseline = values.fetch(:baseline)
      return blocked(values, "baseline_missing") if baseline[:decisions_per_completed_issue].nil? || baseline[:median_decision_time_seconds].nil? || baseline[:completion_rate].nil?
      return blocked(values, "decision_volume_threshold_not_met") unless values[:decisions_per_completed_issue] <= baseline[:decisions_per_completed_issue] * 0.75

      median = values[:median_decision_time_seconds]
      return blocked(values, "decision_time_missing") if median.nil?
      return blocked(values, "decision_time_increased") if median > baseline[:median_decision_time_seconds]

      completion_rate = values[:completion_rate]
      return blocked(values, "completion_rate_missing") if completion_rate.nil?
      return blocked(values, "completion_rate_declined") if completion_rate < baseline[:completion_rate] - 0.05

      Result.new(allowed: true, reason: "thresholds_met", metrics:)
    end

    private

    attr_reader :metrics, :project

    def blocked(values, reason)
      Result.new(allowed: false, reason:, metrics:)
    end
  end
end
