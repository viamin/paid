# frozen_string_literal: true

class SupervisorIncident < ApplicationRecord
  include TenantScoped
  include OperationalSupervisor::SanitizedPayload

  CATEGORIES = %w[conversion cost guardrail queue_starvation rework stage_age].freeze
  SEVERITIES = %w[info warning urgent].freeze
  STATUSES = %w[open waiting_for_human mitigated resolved dismissed].freeze

  belongs_to :account
  belongs_to :supervisor_snapshot, optional: true
  has_many :supervisor_incident_audits, dependent: :destroy

  validates :fingerprint, presence: true, length: { is: 64 }, uniqueness: { scope: :account_id }
  validates :category, inclusion: { in: CATEGORIES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :status, inclusion: { in: STATUSES }
  validates :first_seen_at, :last_seen_at, :retention_expires_at, presence: true
  validate :payloads_are_sanitized
  validate :affected_projects_belong_to_account
  validate :snapshot_belongs_to_account

  scope :open_incidents, -> { where(status: %w[open waiting_for_human mitigated]) }
  scope :expired, -> { where("retention_expires_at <= ?", Time.current) }

  private

  def payloads_are_sanitized
    [ :target_ids, :evidence ].each do |attribute|
      errors.add(attribute, "contains unsupported or unsafe fields") unless sanitized_payload?(public_send(attribute))
    end
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
