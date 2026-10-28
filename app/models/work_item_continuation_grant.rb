# frozen_string_literal: true

# RDR-077 §3: a continuation grant belongs to the work item and its explicitly
# linked continuation chain (issue -> implementation run -> PR -> review ->
# repair), not to the run that happened to carry the manual start. Additional or
# child issues never inherit it.
#
# @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-008
class WorkItemContinuationGrant < ApplicationRecord
  SOURCES = %w[manual_start].freeze

  belongs_to :project
  belongs_to :issue
  belongs_to :created_by, class_name: "User"
  belongs_to :revoked_by, class_name: "User", optional: true

  validates :start_phase, presence: true, inclusion: { in: Automation::Phases::ALL }
  validates :endpoint, presence: true, inclusion: { in: Automation::Phases::CONTINUATION_ENDPOINTS }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validate :endpoint_follows_start_phase
  validate :work_item_belongs_to_project
  validate :actors_belong_to_project_account

  scope :active, -> { where(revoked_at: nil, completed_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :completed, -> { where.not(completed_at: nil) }

  # @spec AUTOMATION-PHASES-005
  def covered_phases
    Automation::Phases.chain(from_phase: start_phase, through: endpoint)
  end

  def covers_phase?(phase)
    covered_phases.include?(phase.to_s)
  end

  def active?
    revoked_at.nil? && completed_at.nil?
  end

  def revoked?
    revoked_at.present?
  end

  def completed?
    completed_at.present?
  end

  # Reaching the endpoint completes the grant. Reopening work never
  # reactivates it: `complete!` is terminal.
  # @spec AUTOMATION-PHASES-008
  def complete!
    return false unless active?

    update!(completed_at: Time.current)
  end

  # Revocation withdraws only this exception. Project defaults may still
  # permit the work independently, which the revocation copy states.
  # @spec AUTOMATION-PHASES-008
  def revoke!(user: nil)
    return false unless active?

    update!(revoked_at: Time.current, revoked_by: user)
  end

  private

  def endpoint_follows_start_phase
    return if start_phase.blank? || endpoint.blank?

    errors.add(:endpoint, "must be the start phase or a later delivery phase") if covered_phases.empty?
  end

  def work_item_belongs_to_project
    return unless project && issue

    errors.add(:issue, "must belong to the grant project") unless issue.project_id == project.id
  end

  def actors_belong_to_project_account
    return unless project

    errors.add(:created_by, "must belong to the project account") if created_by&.account_id != project.account_id
    errors.add(:revoked_by, "must belong to the project account") if revoked_by && revoked_by.account_id != project.account_id
  end
end
