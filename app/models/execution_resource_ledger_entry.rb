# frozen_string_literal: true

# Durable ledger of externally provisioned execution resources: primary
# environments, services, browser/MCP sidecars, workspace/storage volumes,
# networks, preview tunnels, and temporary storage. Each row tracks a single
# provider-owned resource from provisioning through cleanup so orphaned or
# leaked resources can be reconciled.
#
# This is a ledger of *execution resources* only — it is not a general-purpose
# cloud CMDB. Rows are created by the runner/backend that provisions the
# resource and updated as the resource moves through its lifecycle.
#
# Status states:
#
# - +provisioning+ — creation has been requested but not yet confirmed.
# - +active+ — the resource is confirmed provisioned and in use.
# - +cleanup_pending+ — cleanup has been requested but not yet confirmed.
# - +deleted+ — cleanup confirmed complete (terminal).
# - +orphaned+ — reconciliation found a resource with no live owner.
# - +cleanup_failed+ — a cleanup attempt failed; retried from here.
#
# +tags+ carries non-secret ownership/labeling metadata only (e.g. provider
# ownership tags), and +runner_handle+ carries a serialized
# ExecutionRunners::RunnerHandle reference (which can include runner
# metadata such as container environment variables); both are scanned to
# guarantee they never store secret values.
#
# @spec RESOURCE-LEDGER-001
# @spec RESOURCE-LEDGER-002
# @spec RESOURCE-LEDGER-003
# @spec RESOURCE-LEDGER-004
# @spec RESOURCE-LEDGER-007
# @see docs/rdrs/RDR-060-external-execution-resource-ledger.md
# @see docs/intent/execution-resource-ledger/execution-resource-ledger-specs.md
class ExecutionResourceLedgerEntry < ApplicationRecord
  include SecretSafeMetadata

  RESOURCE_KINDS = %w[
    primary_environment
    service
    sidecar
    workspace
    network
    preview_tunnel
    temporary_storage
  ].freeze

  STATUSES = %w[provisioning active cleanup_pending deleted orphaned cleanup_failed].freeze
  ALLOWED_STATUS_TRANSITIONS = {
    "provisioning" => %w[active cleanup_pending orphaned],
    "active" => %w[cleanup_pending orphaned],
    "cleanup_pending" => %w[deleted cleanup_failed],
    "cleanup_failed" => %w[cleanup_pending deleted],
    "orphaned" => %w[cleanup_pending deleted],
    "deleted" => []
  }.freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :agent_run, optional: true

  before_validation :assign_account_from_project
  before_validation :normalize_tags_and_handle

  validates :project, presence: true, on: :create
  validates :runner_type, presence: true, length: { maximum: 64 }
  validates :backend, length: { maximum: 64 }, allow_nil: true
  validates :resource_kind, presence: true, inclusion: { in: RESOURCE_KINDS }
  validates :provider_resource_id, length: { maximum: 255 }, allow_nil: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :cleanup_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :tags_is_object
  validate :tags_secret_safety
  validate :runner_handle_is_object
  validate :runner_handle_secret_safety
  validate :project_matches_agent_run
  validate :account_matches_project
  validate :status_transition_is_allowed, on: :update

  scope :for_account, ->(account) { where(account: account) }
  scope :for_project, ->(project) { where(project: project) }
  scope :for_agent_run, ->(agent_run) { where(agent_run: agent_run) }
  scope :of_kind, ->(resource_kind) { where(resource_kind: resource_kind) }
  scope :provisioning, -> { where(status: "provisioning") }
  scope :active, -> { where(status: "active") }
  scope :cleanup_pending, -> { where(status: "cleanup_pending") }
  scope :deleted, -> { where(status: "deleted") }
  scope :orphaned, -> { where(status: "orphaned") }
  scope :cleanup_failed, -> { where(status: "cleanup_failed") }
  scope :live, -> { where(status: %w[provisioning active cleanup_pending cleanup_failed orphaned]) }

  def provisioning?
    status == "provisioning"
  end

  def active?
    status == "active"
  end

  def cleanup_pending?
    status == "cleanup_pending"
  end

  def deleted?
    status == "deleted"
  end

  def orphaned?
    status == "orphaned"
  end

  def cleanup_failed?
    status == "cleanup_failed"
  end

  # Confirms provisioning succeeded. Idempotent: calling it on an
  # already-active resource does not re-stamp +activated_at+.
  def activate!(provider_resource_id: nil, runner_handle: nil)
    return self if active?

    assign_attributes(
      status: "active",
      activated_at: Time.current,
      provider_resource_id: provider_resource_id || self.provider_resource_id,
      runner_handle: runner_handle || self.runner_handle
    )
    save!
    self
  end

  # Requests cleanup of the resource. Idempotent from any non-terminal state.
  def request_cleanup!
    return self if cleanup_pending?

    assign_attributes(status: "cleanup_pending", cleanup_requested_at: Time.current)
    save!
    self
  end

  # Confirms the resource has been deleted. Terminal and idempotent.
  def mark_deleted!
    return self if deleted?

    assign_attributes(status: "deleted", deleted_at: Time.current)
    save!
    self
  end

  # Flags the resource as orphaned (found during reconciliation with no live
  # owner). Idempotent.
  def mark_orphaned!
    return self if orphaned?

    assign_attributes(status: "orphaned", orphaned_at: Time.current)
    save!
    self
  end

  # Records a failed cleanup attempt, incrementing the retry counter.
  # Idempotent stamping: always records the latest attempt/error, but each
  # call still counts as a distinct attempt.
  def record_cleanup_failure!(error:)
    error_text = error.to_s.strip
    raise ArgumentError, "cleanup failure error is required" if error_text.blank?

    assign_attributes(
      status: "cleanup_failed",
      cleanup_attempts: cleanup_attempts + 1,
      cleanup_last_attempted_at: Time.current,
      cleanup_last_error: error_text,
      cleanup_failed_at: Time.current
    )
    save!
    self
  end

  private

  def assign_account_from_project
    self.account ||= project&.account
  end

  def normalize_tags_and_handle
    self.tags = stringify_metadata(tags) if tags.is_a?(Hash)
    self.runner_handle = stringify_metadata(runner_handle) if runner_handle.is_a?(Hash)
  end

  def tags_is_object
    errors.add(:tags, "must be an object") unless tags.is_a?(Hash)
  end

  def tags_secret_safety
    scan_metadata_for_secrets(tags, attribute: :tags)
  end

  def runner_handle_is_object
    errors.add(:runner_handle, "must be an object") unless runner_handle.is_a?(Hash)
  end

  def runner_handle_secret_safety
    scan_metadata_for_secrets(runner_handle, attribute: :runner_handle)
  end

  def project_matches_agent_run
    return unless project && agent_run

    errors.add(:project, "must match the agent run's project") if project_id != agent_run.project_id
  end

  def account_matches_project
    return unless account_id.present? && project_id.present? && project.present?

    errors.add(:account, "must match the project's account") if account_id != project.account_id
  end

  def status_transition_is_allowed
    return unless will_save_change_to_status?

    from_status, to_status = status_change_to_be_saved
    return if from_status == to_status
    return if ALLOWED_STATUS_TRANSITIONS.fetch(from_status, []).include?(to_status)

    errors.add(:status, "cannot transition from #{from_status} to #{to_status}")
  end
end
