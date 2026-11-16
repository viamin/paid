# frozen_string_literal: true

class SupervisorIncident < ApplicationRecord
  include TenantScoped
  include OperationalSupervisor::SanitizedPayload

  CATEGORIES = %w[conversion cost guardrail queue_starvation rework stage_age].freeze
  SEVERITIES = %w[info warning urgent].freeze
  STATUSES = %w[open waiting_for_human mitigated resolved dismissed].freeze
  OPEN_STATUSES = %w[open waiting_for_human mitigated].freeze
  PROVENANCE_IDENTIFIER_FORMAT = /\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]*\z/
  PROVENANCE_IDENTIFIER_LIMIT = 128

  belongs_to :account
  belongs_to :supervisor_snapshot, optional: true
  has_many :supervisor_incident_audits, dependent: :delete_all

  validates :fingerprint, presence: true, length: { is: 64 }, uniqueness: { scope: :account_id }
  validates :category, inclusion: { in: CATEGORIES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :status, inclusion: { in: STATUSES }
  validates :model_identifier, :prompt_identifier, :policy_identifier, presence: true,
    length: { maximum: PROVENANCE_IDENTIFIER_LIMIT }, format: { with: PROVENANCE_IDENTIFIER_FORMAT }
  validates :first_seen_at, :last_seen_at, :retention_expires_at, presence: true
  # @spec OPERATIONAL-SUPERVISOR-007
  validate :status_transition_is_audited, on: :update
  validate :payloads_are_sanitized
  validate :affected_projects_belong_to_account
  validate :snapshot_belongs_to_account
  after_save :consume_status_transition_authorization

  scope :open_incidents, -> { where(status: OPEN_STATUSES) }
  scope :expired, -> { where("retention_expires_at <= ?", Time.current) }

  def authorize_status_transition!
    @status_transition_authorized = true
  end

  private

  def status_transition_authorized? = @status_transition_authorized == true

  def status_transition_is_audited
    return if !status_changed? || status_transition_authorized?

    errors.add(:status, "transitions must be recorded by OperationalSupervisor::TransitionIncidentStatus")
  end

  def consume_status_transition_authorization
    @status_transition_authorized = nil
  end

  def payloads_are_sanitized
    errors.add(:target_ids, "contains unsupported or unsafe fields") unless sanitized_payload?(target_ids, type: :incident_targets)
    errors.add(:evidence, "contains unsupported or unsafe fields") unless sanitized_payload?(evidence, type: :incident_evidence)
  end

  def affected_projects_belong_to_account
    return if account.blank? || affected_project_ids.blank?
    return if Project.where(account:, id: affected_project_ids).count == affected_project_ids.uniq.count

    errors.add(:affected_project_ids, "must belong to the incident account")
  end

  def snapshot_belongs_to_account
    return if supervisor_snapshot.blank? || supervisor_snapshot.account_id == account_id

    errors.add(:supervisor_snapshot, "must belong to the incident account")
  end
end
