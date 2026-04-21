# frozen_string_literal: true

class ContainerPoolEntry < ApplicationRecord
  STATUSES = %w[warming warm claimed error].freeze

  belongs_to :project
  belongs_to :agent_run, optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :container_id, length: { maximum: 128 }, allow_nil: true
  validates :workspace_volume, presence: true, length: { maximum: 128 }, uniqueness: true
  validates :image, presence: true
  validates :network, presence: true, length: { maximum: 64 }

  scope :warm, -> { where(status: "warm") }
  scope :claimed, -> { where(status: "claimed") }
  scope :warming, -> { where(status: "warming") }
  scope :errored, -> { where(status: "error") }
end
