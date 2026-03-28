# frozen_string_literal: true

class ServiceContainerMetric < ApplicationRecord
  belongs_to :service_container

  validates :container_id, presence: true, length: { maximum: 128 }
  validates :cpu_percent, presence: true, numericality: { greater_than_or_equal_to: 0.0 }
  validates :memory_bytes, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :memory_limit_bytes, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :memory_percent, presence: true, numericality: { greater_than_or_equal_to: 0.0 }
  validates :pids_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :recorded_at, presence: true
end
