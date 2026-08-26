# frozen_string_literal: true

# Durable retry queue for externally managed execution-resource cleanup.
# Reconciliation enqueues crash-window or tag-discovered orphan resources here
# and retries transient provider-delete failures with backoff until cleanup
# succeeds.
#
# @spec CONTAINER-RUNTIME-036
class ExecutionResourceCleanup < ApplicationRecord
  STATUS_PENDING = "pending"
  STATUS_COMPLETED = "completed"
  STATUSES = [ STATUS_PENDING, STATUS_COMPLETED ].freeze

  belongs_to :account, optional: true
  belongs_to :project, optional: true
  belongs_to :agent_run, optional: true
  belongs_to :provisioning_intent, optional: true

  before_validation :normalize_ownership_tags
  before_validation :normalize_provider_resource_host

  validates :runner_type, :resource_kind, :provider_resource_id, :status, :next_attempt_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :ownership_tags_is_object

  scope :pending, -> { where(status: STATUS_PENDING) }
  scope :completed, -> { where(status: STATUS_COMPLETED) }
  scope :due, -> { pending.where("next_attempt_at <= ?", Time.current) }

  def completed?
    status == STATUS_COMPLETED
  end

  def mark_completed!
    return self if completed?

    update!(status: STATUS_COMPLETED, completed_at: Time.current, last_error: nil)
    self
  end

  def record_failure!(error:, next_attempt_at:)
    update!(
      attempts: attempts + 1,
      last_error: error.to_s,
      last_attempted_at: Time.current,
      next_attempt_at: next_attempt_at,
      status: STATUS_PENDING
    )
    self
  end

  private

  def normalize_ownership_tags
    self.ownership_tags = ownership_tags.deep_stringify_keys if ownership_tags.is_a?(Hash)
  end

  def normalize_provider_resource_host
    self.provider_resource_host = provider_resource_host.to_s
  end

  def ownership_tags_is_object
    errors.add(:ownership_tags, "must be an object") unless ownership_tags.is_a?(Hash)
  end
end
