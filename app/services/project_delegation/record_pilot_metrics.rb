# frozen_string_literal: true

module ProjectDelegation
  # Single write path for RDR-080 pilot measurements. Callers supply the
  # measured inputs for one project, posture cohort, and window; this service
  # validates the structure, computes the aggregates, and upserts idempotently
  # per project, posture, and window start. Every row pins the governing
  # intent/acceptance/evidence revisions and every reversal event carries both
  # its settled and its reversing revision, so joins back to source evidence
  # stay revision aware.
  #
  # @spec PROJECT-DELEGATION-007
  class RecordPilotMetrics
    class Error < StandardError; end
    class InvalidMeasurement < Error; end

    REVERSAL_KEYS = %w[settled_revision reversing_revision].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, posture:, window_started_at:, window_ended_at:, completed_issues:, total_issues:,
      decision_seconds:, reversals:, exclusions:, revisions:, actor: nil, evidence: {})
      @project = project
      @posture = posture.to_s
      @window_started_at = window_started_at
      @window_ended_at = window_ended_at
      @completed_issues = completed_issues
      @total_issues = total_issues
      @decision_seconds = Array(decision_seconds)
      @reversals = Array(reversals)
      @exclusions = exclusions
      @revisions = revisions
      @actor = actor
      @evidence = evidence
    end

    def call
      validate!

      metric = upsert
      Audit::RecordEvent.call(
        action: "project_delegation.pilot_metrics_recorded",
        actor: actor,
        subject: metric,
        metadata: { "posture" => posture, "window_started_at" => window_started_at&.iso8601,
                    "completed_issues" => completed_issues, "inbox_decisions" => metric.inbox_decisions }
      )
      metric
    end

    private

    attr_reader :project, :posture, :window_started_at, :window_ended_at, :completed_issues, :total_issues,
      :decision_seconds, :reversals, :exclusions, :revisions, :actor, :evidence

    def validate!
      ensure_posture!
      ensure_window!
      ensure_counts!
      ensure_samples!
      ensure_reversals!
      ensure_exclusions!
      ensure_revisions!
    end

    def ensure_posture!
      return if PilotMetric::POSTURES.include?(posture)

      raise InvalidMeasurement, "posture must be one of #{PilotMetric::POSTURES.join(', ')}"
    end

    def ensure_window!
      if window_started_at.blank? || window_ended_at.blank? || window_ended_at <= window_started_at
        raise InvalidMeasurement, "the measurement window must end after it starts"
      end
    end

    def ensure_counts!
      [ completed_issues, total_issues ].each do |count|
        next if count.is_a?(Integer) && count >= 0

        raise InvalidMeasurement, "issue counts must be non-negative integers"
      end
      return if completed_issues <= total_issues

      raise InvalidMeasurement, "completed_issues must not exceed total_issues"
    end

    def ensure_samples!
      unless decision_seconds.all? { |sample| sample.is_a?(Numeric) && sample >= 0 }
        raise InvalidMeasurement, "decision_seconds must be non-negative numbers"
      end
    end

    def ensure_reversals!
      reversals.each do |reversal|
        pins = reversal.is_a?(Hash) && REVERSAL_KEYS.all? { |key| reversal[key].is_a?(String) && reversal[key].present? }
        next if pins

        raise InvalidMeasurement, "each reversal event must pin #{REVERSAL_KEYS.join(' and ')}"
      end
    end

    def ensure_exclusions!
      return if exclusions.is_a?(Hash) && exclusions.all? { |reason, count| reason.is_a?(String) && reason.present? && count.is_a?(Integer) && count >= 0 }

      raise InvalidMeasurement, "exclusions must map reason codes to non-negative counts"
    end

    def ensure_revisions!
      missing = PilotMetric::REVISION_KEYS.reject { |key| revisions.is_a?(Hash) && revisions[key].is_a?(String) && revisions[key].present? }

      return if missing.empty?

      raise InvalidMeasurement, "the measurement must pin #{missing.join(', ')}"
    end

    def upsert
      project.account.transaction do
        PilotMetric.find_or_initialize_by(project:, posture:, window_started_at:)
          .then { |metric| metric.update!(**measured_attributes) && metric }
      end
    end

    def measured_attributes
      {
        account: project.account,
        window_ended_at:,
        completed_issues:,
        total_issues:,
        inbox_decisions: decision_seconds.size,
        median_decision_seconds: median,
        p90_decision_seconds: percentile90,
        completion_rate: ratio(completed_issues, total_issues),
        reversed_decisions: reversals.size,
        reversal_rate: ratio(reversals.size, decision_seconds.size),
        revisions:,
        reversals:,
        exclusions:,
        evidence: { **evidence.to_h, "decision_seconds" => decision_seconds }
      }
    end

    def median
      return nil if decision_seconds.empty?

      sorted = decision_seconds.sort
      middle = sorted.size / 2
      return sorted[middle].to_f if sorted.size.odd?

      (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def percentile90
      return nil if decision_seconds.empty?

      sorted = decision_seconds.sort
      rank = (0.9 * sorted.size).ceil
      sorted[rank - 1].to_f
    end

    def ratio(numerator, denominator)
      return 0 if denominator.nil? || denominator.zero?

      Rational(numerator, denominator).to_f.round(5)
    end
  end
end
