# frozen_string_literal: true

class SupervisorSnapshot < ApplicationRecord
  include TenantScoped
  include OperationalSupervisor::SanitizedPayload

  belongs_to :account
  has_many :supervisor_incidents, dependent: :nullify

  validates :digest, :metric_provenance, presence: true
  validates :captured_at, :retention_expires_at, presence: true
  validate :payloads_are_sanitized
  validate :provenance_describes_metrics
  validate :included_projects_belong_to_account
  validate :retention_follows_capture

  scope :expired, -> { where("retention_expires_at <= ?", Time.current) }

  private

  def payloads_are_sanitized
    errors.add(:digest, "contains unsupported or unsafe fields") unless sanitized_payload?(digest, type: :snapshot_digest)
    errors.add(:metric_provenance, "contains unsupported or unsafe fields") unless sanitized_payload?(metric_provenance, type: :metric_provenance)
  end

  def included_projects_belong_to_account
    return if account.blank? || included_project_ids.blank?
    return if Project.where(account:, id: included_project_ids).count == included_project_ids.uniq.count

    errors.add(:included_project_ids, "must belong to the snapshot account")
  end

  def provenance_describes_metrics
    return unless digest.is_a?(Hash) && digest["metrics"].is_a?(Array) && metric_provenance.is_a?(Array)
    return if digest["metrics"].pluck("name").sort == metric_provenance.pluck("name").sort

    errors.add(:metric_provenance, "must describe each metric exactly once")
  end

  def retention_follows_capture
    return if captured_at.blank? || retention_expires_at.blank? || retention_expires_at > captured_at

    errors.add(:retention_expires_at, "must follow capture time")
  end
end
