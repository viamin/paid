# frozen_string_literal: true

class OnboardingStep < ApplicationRecord
  STEPS = %w[account_profile github_token first_project configure_defaults].freeze
  STATUSES = %w[pending in_progress completed skipped].freeze

  belongs_to :account

  validates :step, presence: true, inclusion: { in: STEPS }, uniqueness: { scope: :account_id }
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :ordered, -> { order(:position) }
  scope :completed, -> { where(status: "completed") }
  scope :pending, -> { where(status: "pending") }

  def completed?
    status == "completed"
  end

  def skipped?
    status == "skipped"
  end

  def pending?
    status == "pending"
  end

  def in_progress?
    status == "in_progress"
  end

  def complete!(metadata_updates = {})
    update!(
      status: "completed",
      completed_at: Time.current,
      metadata: self.metadata.merge(metadata_updates)
    )
  end

  def skip!
    update!(
      status: "skipped",
      completed_at: Time.current
    )
  end

  def mark_in_progress!
    update!(status: "in_progress") if pending?
  end
end
