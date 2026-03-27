# frozen_string_literal: true

class ServiceContainerMetric < ApplicationRecord
  belongs_to :service_container

  validates :container_id, presence: true, length: { maximum: 128 }
  validates :cpu_percent, presence: true
  validates :memory_bytes, presence: true
  validates :memory_limit_bytes, presence: true
  validates :memory_percent, presence: true
  validates :recorded_at, presence: true
end
