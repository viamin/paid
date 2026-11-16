# frozen_string_literal: true

class SupervisorIncidentAudit < ApplicationRecord
  include TenantScoped
  include OperationalSupervisor::SanitizedPayload

  ACTIONS = %w[opened observed status_changed].freeze

  belongs_to :account
  belongs_to :supervisor_incident

  validates :action, inclusion: { in: ACTIONS }
  validates :occurred_at, presence: true
  validate :evidence_is_sanitized
  validate :incident_belongs_to_account

  def readonly?
    persisted? || super
  end

  private

  def evidence_is_sanitized
    errors.add(:evidence, "contains unsupported or unsafe fields") unless sanitized_payload?(evidence)
  end

  def incident_belongs_to_account
    return if supervisor_incident.blank? || supervisor_incident.account_id == account_id

    errors.add(:supervisor_incident, "must belong to the audit account")
  end
end
