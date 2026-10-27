# frozen_string_literal: true

# RDR-077 §3: a continuation grant belongs to the work item and its explicitly
# linked continuation chain (issue -> implementation run -> PR -> review ->
# repair), not to the run that happened to carry the manual start. Additional or
# child issues never inherit it.
#
# A grant is delegated automation authority, so it is scoped to one project and
# one of that project's work items, names the author who delegated it, and
# leaves an account-scoped audit trail when it is created and revoked.
#
# @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-008
# @spec AUTOMATION-PHASES-019
class WorkItemContinuationGrant < ApplicationRecord
  SOURCES = %w[manual_start].freeze

  belongs_to :project
  belongs_to :issue
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  validates :start_phase, presence: true, inclusion: { in: Automation::Phases::ALL }
  validates :endpoint, presence: true, inclusion: { in: Automation::Phases::CONTINUATION_ENDPOINTS }
  validates :source, presence: true, inclusion: { in: SOURCES }
  # The author is required when the grant is delegated. Later nullification of
  # a deleted user keeps the authorization record readable.
  validates :created_by, presence: true, on: :create
  validate :endpoint_follows_start_phase
  validate :issue_belongs_to_project
  validate :author_belongs_to_project_account

  scope :active, -> { where(revoked_at: nil, completed_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :completed, -> { where.not(completed_at: nil) }

  after_create_commit :record_creation_audit_event
  after_update_commit :record_revocation_audit_event, if: :saved_change_to_revoked_at?

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

  # @spec AUTOMATION-PHASES-019
  def record_creation_audit_event
    record_audit_event("continuation_grant.created", actor: created_by)
  end

  # @spec AUTOMATION-PHASES-019
  def record_revocation_audit_event
    record_audit_event("continuation_grant.revoked", actor: revoked_by || created_by)
  end

  private

  def endpoint_follows_start_phase
    return if start_phase.blank? || endpoint.blank?

    errors.add(:endpoint, "must be the start phase or a later delivery phase") if covered_phases.empty?
  end

  # A grant authorizes work in its own project only. Linking another tenant's
  # work item would let a grant read as authority over work it never covered.
  # @spec AUTOMATION-PHASES-019
  def issue_belongs_to_project
    return if issue.blank? || project.blank?
    return if issue.project_id == project.id

    errors.add(:issue, "must belong to the grant's project")
  end

  def author_belongs_to_project_account
    return if created_by.blank? || project.blank?
    return if created_by.account_id == project.account_id

    errors.add(:created_by, "must belong to the grant's account")
  end

  def record_audit_event(action, actor:)
    Audit::RecordEvent.call(
      action:,
      actor:,
      subject: self,
      metadata: audit_metadata
    )
  rescue StandardError => e
    # The authorization itself is already durable; an audit failure must not
    # undo it, but it has to stay visible to an operator.
    Rails.logger.error(
      message: "automation.continuation_grant_audit_failed",
      action:,
      grant_id: id,
      project_id: project_id,
      error_class: e.class.name,
      error_message: e.message
    )
  end

  def audit_metadata
    {
      "work_item_continuation_grant_id" => id,
      "project_id" => project_id,
      "issue_id" => issue_id,
      "start_phase" => start_phase,
      "endpoint" => endpoint,
      "covered_phases" => covered_phases
    }
  end
end
