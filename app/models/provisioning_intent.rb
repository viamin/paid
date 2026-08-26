# frozen_string_literal: true

# Execution-resource provisioning-intent ledger row (RDR-060). Records a
# runner's intent to create an execution resource BEFORE the provider create
# call so a crash between provider creation and runner-handle persistence
# leaves enough information to reconcile the orphaned resource.
#
# @spec CONTAINER-RUNTIME-025
# @spec CONTAINER-RUNTIME-027
class ProvisioningIntent < ApplicationRecord
  # Ledger lifecycle states.
  #   pending  — intent recorded, provider create call not yet issued
  #   created  — provider resource created, identifier captured
  #   linked   — runner handle linked (terminal success)
  #   failed   — create failed or the created resource was abandoned/cleaned up
  STATUS_PENDING = "pending"
  STATUS_CREATED = "created"
  STATUS_LINKED = "linked"
  STATUS_FAILED = "failed"
  STATUSES = [ STATUS_PENDING, STATUS_CREATED, STATUS_LINKED, STATUS_FAILED ].freeze

  # A ledger row left in the +created+ state with a provider resource identifier
  # but no linked handle is the crash-window signal a reconciliation scan looks
  # for: the resource was created but the runner never persisted the handle.
  RECONCILEABLE_STATUSES = [ STATUS_PENDING, STATUS_CREATED ].freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :agent_run, optional: true

  validates :resource_kind, :runner_type, :environment, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :attempt, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :reconcileable, -> { where(status: RECONCILEABLE_STATUSES) }
  scope :orphans, -> { where(status: STATUS_CREATED, runner_handle: nil).where.not(provider_resource_id: nil) }

  def pending?
    status == STATUS_PENDING
  end

  def created?
    status == STATUS_CREATED
  end

  def linked?
    status == STATUS_LINKED
  end

  def failed?
    status == STATUS_FAILED
  end

  # True when the provider resource was created but the runner handle was never
  # linked — the crash-window state a reconciliation scan resolves.
  def orphaned?
    created? && provider_resource_id.present? && runner_handle.blank?
  end

  def mark_reconciled_cleanup!(cleanup_id: nil)
    updated_metadata = metadata.deep_dup
    updated_metadata["cleanup_reconciled"] = true
    updated_metadata["execution_resource_cleanup_id"] = cleanup_id if cleanup_id.present?

    update!(
      status: STATUS_FAILED,
      reconciled_at: Time.current,
      metadata: updated_metadata
    )
  end
end
