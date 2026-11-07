# frozen_string_literal: true

# One revision-aware metric snapshot for a delegation-pilot enrollment: the
# durable evidence RDR-080's expansion thresholds are evaluated against. A
# `conservative_baseline` snapshot is captured at enrollment from the
# project's own pre-pilot window; `bounded_delivery` snapshots accumulate on
# the daily sweep. Snapshots are immutable evidence — pausing expansion never
# rewrites them.
#
# @spec PROJECT-DELEGATION-007
class DelegationPilotMetricSnapshot < ApplicationRecord
  POSTURES = %w[conservative_baseline bounded_delivery].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :enrollment, class_name: "DelegationPilotEnrollment", inverse_of: :snapshots

  validates :posture, presence: true, inclusion: { in: POSTURES }
  validates :window_started_at, presence: true
  validates :window_ended_at, presence: true
  # The unique (enrollment, posture, window_ended_at) index is the concurrency
  # backstop for idempotent recording.
  validates :window_ended_at, uniqueness: { scope: %i[enrollment_id posture] }
  validate :window_order
  validate :project_matches_enrollment
  validate :account_matches_enrollment

  scope :conservative_baseline, -> { where(posture: "conservative_baseline") }
  scope :bounded_delivery, -> { where(posture: "bounded_delivery") }

  private

  def window_order
    return unless window_started_at && window_ended_at

    errors.add(:window_started_at, "must precede the window end") unless window_started_at < window_ended_at
  end

  def project_matches_enrollment
    errors.add(:project, "must match the enrollment") if project && enrollment && project_id != enrollment.project_id
  end

  def account_matches_enrollment
    errors.add(:account, "must match the enrollment") if account && enrollment && account_id != enrollment.account_id
  end
end
