# frozen_string_literal: true

# Durable worker-health state used to stop admission after repeated host failures.
# @spec APPLE-ATTEMPT-015
class AppleVerificationWorkerHealth < ApplicationRecord
  STATUSES = %w[healthy quarantined].freeze

  belongs_to :apple_worker_profile

  validates :status, inclusion: { in: STATUSES }
  validates :consecutive_failures, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def healthy?
    status == "healthy"
  end

  def quarantined?
    status == "quarantined"
  end
end
