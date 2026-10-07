# frozen_string_literal: true

# Durable, operator-visible reconciliation state for a Dependabot alert. A
# Dependabot PR is evidence of an attempted remedy, never proof that the
# advisory is fixed. # @spec DEPENDABOT-COVERAGE-001
class DependabotAlertCoverage < ApplicationRecord
  GRACE_PERIOD = 7.days
  COVERAGE_STATES = %w[
    awaiting_processing effective_pr_open effective_pr_closed_unmerged
    merged_still_vulnerable incompatible_constraints no_patched_version
    unknown accepted ingestion_failed
  ].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :accepted_by, class_name: "User", optional: true

  validates :alert_number, :dependency_name, :dependency_ecosystem, :advisory_ghsa_id,
    :alert_state, :coverage_state, :reason, :first_detected_at, :last_detected_at, presence: true
  validates :coverage_state, inclusion: { in: COVERAGE_STATES }
  validates :alert_number, uniqueness: { scope: :project_id }
  validate :account_matches_project
  validate :acceptance_has_operator_context

  def accepted?
    coverage_state == "accepted" && acceptance_expires_at&.future?
  end

  def uncovered?
    !accepted? && !effective_pr_open?
  end

  def effective_pr_open?
    coverage_state == "effective_pr_open"
  end

  def escalation_due?
    return false unless uncovered?
    return false unless escalated_at.nil?
    return false unless uncovered_since&.<= GRACE_PERIOD.ago

    true
  end

  # @spec DEPENDABOT-COVERAGE-001
  def accept!(owner:, reason:, expires_at:)
    update!(
      accepted_by: owner, acceptance_reason: reason, acceptance_expires_at: expires_at,
      coverage_state: "accepted", reason: "operator_accepted"
    )
  end

  private

  def account_matches_project
    return unless account && project
    return if account_id == project.account_id

    errors.add(:account, "must match the project's account")
  end

  def acceptance_has_operator_context
    return unless coverage_state == "accepted"
    return if accepted_by && acceptance_reason.present? && acceptance_expires_at.present?

    errors.add(:base, "accepted alerts require an owner, reason, and expiry")
  end
end
