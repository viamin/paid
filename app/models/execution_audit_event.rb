# frozen_string_literal: true

# RDR-061 — append-only execution infrastructure/security audit trail.
#
# Distinct from operational logs (AgentRunLog, debug/agent-output text) and
# telemetry (RunnerAuthAttempt, container_metrics): this model exists to
# answer "what security-relevant thing happened to this run's execution
# environment, and who/what caused it" — credential resolution, network
# policy application, image/resource provisioning — as an immutable record.
# Rows are created once and never updated (no `updated_at`, no logidze);
# retention is enforced by `ExecutionAuditEventRetentionJob`.
#
# @spec EXECUTION-AUDIT-001
# @spec EXECUTION-AUDIT-002
# @spec EXECUTION-AUDIT-003
class ExecutionAuditEvent < ApplicationRecord
  include SecretSafeMetadata

  EVENT_NAME_PATTERN = /\A[a-z0-9]+(_[a-z0-9]+)*(\.[a-z0-9]+(_[a-z0-9]+)*)+\z/

  CREDENTIAL_CLASS_PROXY_RESTRICTED = "proxy_restricted"
  CREDENTIAL_CLASS_SUBSCRIPTION_AUTH = "subscription_auth"
  CREDENTIAL_CLASS_DIRECT_OUTBOUND = "direct_outbound"
  CREDENTIAL_CLASS_NONE = "none"
  CREDENTIAL_CLASSES = [
    CREDENTIAL_CLASS_PROXY_RESTRICTED,
    CREDENTIAL_CLASS_SUBSCRIPTION_AUTH,
    CREDENTIAL_CLASS_DIRECT_OUTBOUND,
    CREDENTIAL_CLASS_NONE
  ].freeze

  # String attributes (beyond `metadata`) that must never carry secret-shaped
  # values, since they are free text a caller could accidentally populate
  # with credential material.
  SECRET_SCANNED_ATTRIBUTES = %i[
    actor_id runner_key backend image_reference image_digest
    resource_id correlation_id
  ].freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :agent_run, optional: true

  before_validation :assign_project_from_agent_run
  before_validation :assign_account_from_project_or_run
  before_validation :assign_occurred_at
  before_validation :normalize_credential_classes
  before_validation :enforce_metadata_secret_safety
  before_validation :strip_unknown_metadata

  validates :event_name, presence: true, length: { maximum: 100 }, format: { with: EVENT_NAME_PATTERN }
  validates :event_version, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :occurred_at, presence: true
  validates :actor_type, length: { maximum: 50 }, allow_nil: true
  validates :actor_id, length: { maximum: 100 }, allow_nil: true
  validates :runner_key, length: { maximum: 64 }, allow_nil: true
  validates :backend, length: { maximum: 64 }, allow_nil: true
  validates :image_reference, length: { maximum: 255 }, allow_nil: true
  validates :image_digest, length: { maximum: 128 }, allow_nil: true
  validates :resource_type, length: { maximum: 50 }, allow_nil: true
  validates :resource_id, length: { maximum: 255 }, allow_nil: true
  validates :correlation_id, length: { maximum: 255 }, allow_nil: true
  validate :metadata_is_object
  validate :credential_classes_are_valid
  validate :network_policy_is_object
  validate :project_matches_agent_run
  validate :account_matches_project
  validate :no_secret_shaped_string_attributes

  scope :for_account, ->(account) { where(account: account) }
  scope :for_project, ->(project) { where(project: project) }
  scope :for_agent_run, ->(agent_run) { where(agent_run: agent_run) }
  scope :for_runner_key, ->(runner_key) { where(runner_key: runner_key.to_s) }
  scope :for_image_reference, ->(image_reference) { where(image_reference: image_reference.to_s) }
  scope :for_resource, ->(resource_type, resource_id) { where(resource_type: resource_type.to_s, resource_id: resource_id.to_s) }
  scope :for_correlation_id, ->(correlation_id) { where(correlation_id: correlation_id.to_s) }
  scope :by_event_name, ->(event_name) { where(event_name: event_name.to_s) }
  scope :recent, -> { order(occurred_at: :desc, id: :desc) }

  def self.record!(**attrs)
    create!(attrs)
  end

  private

  def assign_project_from_agent_run
    self.project ||= agent_run&.project
  end

  def assign_account_from_project_or_run
    self.account ||= project&.account
  end

  def assign_occurred_at
    self.occurred_at ||= Time.current
  end

  def normalize_credential_classes
    self.credential_classes = Array(credential_classes).map(&:to_s) if credential_classes.present?
  end

  def credential_classes_are_valid
    return if credential_classes.blank?

    unless credential_classes.is_a?(Array)
      errors.add(:credential_classes, "must be an array")
      return
    end

    invalid = credential_classes - CREDENTIAL_CLASSES
    errors.add(:credential_classes, "contains unsupported value(s): #{invalid.join(', ')}") if invalid.any?
  end

  def network_policy_is_object
    errors.add(:network_policy, "must be an object") unless network_policy.is_a?(Hash)
  end

  def project_matches_agent_run
    return unless project && agent_run

    errors.add(:project, "must match the agent run's project") if project_id != agent_run.project_id
  end

  # The denormalized account_id is the RLS tenant key (see the
  # `tenant_isolation` policy in CreateExecutionAuditEvents); a caller that
  # builds `account: a, project: b_owned_by_other_account` would otherwise
  # produce a row whose account_id disagrees with its project, so reject it
  # here before persistence.
  def account_matches_project
    return unless account_id.present? && project_id.present? && project.present?

    errors.add(:account, "must match the project's account") if account_id != project.account_id
  end

  def no_secret_shaped_string_attributes
    SECRET_SCANNED_ATTRIBUTES.each do |attribute|
      value = public_send(attribute)
      next if value.blank?

      errors.add(attribute, "must not contain a secret-shaped value") if self.class.secret_like?(value)
    end
  end
end
