# frozen_string_literal: true

# Durable identity for a pending independent intent-conformance review. The
# unique database index makes repeated PR scans idempotent across workers.
class IntentConformanceReviewSchedule < ApplicationRecord
  STATUSES = %w[pending running completed].freeze

  belongs_to :project
  belongs_to :issue

  validates :pr_head_sha, :approved_design_revision, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :attempts_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  def pending? = status == "pending"
  def running? = status == "running"
  def completed? = status == "completed"
end
