# frozen_string_literal: true

# One delegation-pilot enrollment per opted-in project (RDR-080 measurement).
# The enrollment is the durable pilot record: it pins the `bounded_delivery`
# posture, the enrolling actor, and — when expansion is paused — the reason
# and evidence a human must review. Broadening stays disabled unless
# `ProjectDelegation::ExpansionGuard` permits it from recorded snapshots.
#
# @spec PROJECT-DELEGATION-007
class DelegationPilotEnrollment < ApplicationRecord
  POSTURES = %w[bounded_delivery].freeze
  STATUSES = %w[active paused].freeze
  PAUSE_REASONS = %w[material_reversal security_tenant_trust_breach missing_evidence].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :enrolled_by, class_name: "User", optional: true

  has_many :snapshots, class_name: "DelegationPilotMetricSnapshot", dependent: :destroy, inverse_of: :enrollment

  # The unique project index is the concurrency backstop; this validation is
  # the model-level contract for callers that build before save.
  validates :project, uniqueness: true
  validates :posture, presence: true, inclusion: { in: POSTURES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :enrolled_at, presence: true
  validates :pause_reason, presence: { message: "must be present when paused" },
    inclusion: { in: PAUSE_REASONS }, if: :paused?
  validates :pause_reason, absence: true, unless: :paused?
  validate :account_matches_project

  scope :active, -> { where(status: "active") }
  scope :by_posture, ->(posture) { where(posture: posture) }

  def active?
    status == "active"
  end

  def paused?
    status == "paused"
  end

  def paused!(**attributes)
    update!({ status: "paused", paused_at: Time.current }.merge(attributes))
  end

  def latest_snapshot(posture)
    snapshots.where(posture: posture.to_s).order(window_ended_at: :desc, id: :desc).first
  end

  private

  def account_matches_project
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
  end
end
