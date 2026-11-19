# frozen_string_literal: true

# A report-local evidence snapshot. It is never reused by a later scan.
# @spec MAINT-025 MAINT-027 MAINT-043
class MaintenanceFindingOccurrence < ApplicationRecord
  ASSESSMENTS = %w[actionable needs_review not_actionable].freeze
  DISPOSITIONS = %w[unverified verified rejected].freeze
  EVIDENCE_SOURCES = %w[agent tool].freeze

  belongs_to :account
  belongs_to :maintenance_report
  belongs_to :maintenance_finding

  validates :category, :claim, :verification_disposition, :observed_status, presence: true
  validates :agent_assessment, inclusion: { in: ASSESSMENTS }, allow_nil: true
  validates :evidence_source, inclusion: { in: EVIDENCE_SOURCES }
  validates :verification_disposition, inclusion: { in: DISPOSITIONS }
  validates :maintenance_finding_id, uniqueness: { scope: :maintenance_report_id }
  validate :tenant_matches_report_and_finding

  private

  def tenant_matches_report_and_finding
    return if account_id.blank? || maintenance_report.blank? || maintenance_finding.blank?
    return if account_id == maintenance_report.account_id && account_id == maintenance_finding.account_id &&
      maintenance_report.project_id == maintenance_finding.project_id

    errors.add(:account, "must match the report and canonical finding")
  end
end
