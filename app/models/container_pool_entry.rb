# frozen_string_literal: true

class ContainerPoolEntry < ApplicationRecord
  STATUSES = %w[warming warm claimed error].freeze
  WARMING_STALE_AFTER = 15.minutes

  belongs_to :project
  belongs_to :agent_run, optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :container_id, length: { maximum: 128 }, allow_nil: true
  validates :container_host, length: { maximum: 64 }, allow_nil: true
  validates :workspace_volume, presence: true, length: { maximum: 128 }, uniqueness: true
  validates :image, presence: true
  validates :network, presence: true, length: { maximum: 64 }

  scope :warm, -> { where(status: "warm") }
  scope :claimed, -> { where(status: "claimed") }
  scope :warming, -> { where(status: "warming") }
  scope :active_warming, -> { warming.where(created_at: WARMING_STALE_AFTER.ago..) }
  scope :stale_warming, -> { warming.where(created_at: ...WARMING_STALE_AFTER.ago) }
  scope :errored, -> { where(status: "error") }

  # Persists the runtime image selection the warmed container was actually
  # provisioned with, so a later claim can attribute the exact digest to the
  # claiming run even if the catalog default moves between warm and claim
  # (RDR-059 / IMMUTABLE-IMAGE-002).
  def record_runtime_image_selection!(selection_metadata)
    # @spec IMMUTABLE-IMAGE-002
    return if selection_metadata.blank?

    update!(runtime_image_metadata: selection_metadata)
  end

  def runtime_image_selection
    runtime_image_metadata.presence
  end
end
