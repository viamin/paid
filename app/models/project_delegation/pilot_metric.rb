# frozen_string_literal: true

module ProjectDelegation
  # One durable RDR-080 pilot measurement row per project, posture cohort,
  # and window start. Written only through {RecordPilotMetrics}, which pins
  # the joined revisions and computes the aggregates from measured inputs.
  #
  # @spec PROJECT-DELEGATION-007
  class PilotMetric < ApplicationRecord
    POSTURES = %w[conservative bounded_delivery].freeze
    REVISION_KEYS = %w[intent_revision acceptance_revision evidence_revision].freeze

    belongs_to :account
    belongs_to :project

    validates :posture, presence: true, inclusion: { in: POSTURES }
    validates :window_started_at, :window_ended_at, presence: true
    validates :completed_issues, :total_issues, :inbox_decisions, :reversed_decisions,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :completion_rate, :reversal_rate,
      numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
    validates :median_decision_seconds, :p90_decision_seconds,
      numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
    validate :window_ends_after_it_starts
    validate :completed_issues_within_total
    validate :pins_every_governing_revision

    def self.latest_for(project, posture)
      where(project:, posture:).order(window_started_at: :desc, id: :desc).first
    end

    # Human Inbox decisions per completed issue for this window.
    def decisions_per_completed_issue
      return nil unless completed_issues.positive?

      inbox_decisions.to_f / completed_issues
    end

    # Settled decisions later reversed materially and attributable to
    # delegated work — the RDR-080 expansion-blocking reversal set.
    def material_attributable_reversals
      Array(reversals).select do |reversal|
        reversal["material"] == true && reversal["attributable_to_delegated_work"] == true
      end
    end

    private

    def window_ends_after_it_starts
      return if window_started_at.blank? || window_ended_at.blank?
      return if window_ended_at > window_started_at

      errors.add(:window_ended_at, "must end after the window starts")
    end

    def completed_issues_within_total
      return if completed_issues.nil? || total_issues.nil?
      return if completed_issues <= total_issues

      errors.add(:completed_issues, "must not exceed the measured issue total")
    end

    def pins_every_governing_revision
      missing = REVISION_KEYS.reject { |key| revisions.is_a?(Hash) && revisions[key].is_a?(String) && revisions[key].present? }
      return if missing.empty?

      errors.add(:revisions, "must pin #{missing.join(', ')}")
    end
  end
end
