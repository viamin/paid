# frozen_string_literal: true

# Immutable report for one maintenance run. Canonical findings evolve across
# scans, while occurrences preserve exactly what this pinned run observed.
# @spec MAINT-020 MAINT-021 MAINT-022
class MaintenanceReport < ApplicationRecord
  OUTCOMES = %w[clean completed partial cancelled budget_exhausted].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :agent_run
  has_many :finding_occurrences, class_name: "MaintenanceFindingOccurrence", dependent: :destroy

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :agent_run_id, uniqueness: true
  validate :belongs_to_maintenance_run
  validate :tenant_matches_project_and_run
  validate :outcome_matches_coverage

  private

  def belongs_to_maintenance_run
    errors.add(:agent_run, "must be a maintenance run") unless agent_run&.maintenance_goal?
  end

  def tenant_matches_project_and_run
    return if account.blank? || project.blank? || agent_run.blank?
    return if account_id == project.account_id && project_id == agent_run.project_id

    errors.add(:account, "must match the report project and run")
  end

  def outcome_matches_coverage
    return unless outcome.in?(%w[clean completed partial])
    return errors.add(:outcome, "must be partial when a check is incomplete") if incomplete_checks.any? && outcome != "partial"
    return unless incomplete_checks.empty?

    errors.add(:outcome, "must not be partial when all checks completed") if outcome == "partial"
    errors.add(:outcome, "must be completed when findings exist") if outcome == "clean" && finding_occurrences.any?
  end
end
