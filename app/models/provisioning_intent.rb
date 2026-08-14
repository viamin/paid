# frozen_string_literal: true

# == Schema Information
#
# Table name: provisioning_intents
#
#  id                     :bigint(8)        not null, primary key
#  account_id             :bigint(8)        not null
#  agent_run_id           :bigint(8)
#  attempt                :integer          default(0), not null
#  environment            :string(100)      not null
#  metadata               :jsonb            not null
#  ownership_tags         :jsonb            not null
#  project_id             :bigint(8)
#  provider_resource_host :string(200)
#  provider_resource_id   :string(200)
#  runner_handle          :jsonb
#  runner_type            :string(50)       not null
#  reconciled_at          :datetime
#  resource_kind          :string(100)      not null
#  status                 :string(50)       default("pending"), not null
#  tagging_supported      :boolean          default(TRUE), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
# Execution-resource provisioning-intent ledger row (RDR-058). Records a
# runner's intent to create an execution resource BEFORE the provider create
# call so a crash between provider creation and runner-handle persistence
# leaves enough information to reconcile the orphaned resource.
#
# @spec CONTAINER-RUNTIME-018
# @spec CONTAINER-RUNTIME-020
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
  scope :orphans, -> { where(status: STATUS_CREATED).where.not(provider_resource_id: nil) }

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
end
