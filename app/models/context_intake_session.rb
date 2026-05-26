# frozen_string_literal: true

class ContextIntakeSession < ApplicationRecord
  STATUSES = %w[in_progress completed stale archived].freeze
  STALENESS_THRESHOLD = 90.days

  belongs_to :project
  belongs_to :started_by, class_name: "User"

  has_many :context_intake_responses, dependent: :destroy

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :schema_version, presence: true, length: { maximum: 20 }
  validates :current_step, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :by_status, ->(status) { where(status: status) }
  scope :in_progress, -> { by_status("in_progress") }
  scope :completed, -> { by_status("completed") }
  scope :stale, -> { by_status("stale") }
  scope :latest_first, -> { order(created_at: :desc) }
  scope :for_project, ->(project) { where(project: project) }

  def complete!
    update!(status: "completed", completed_at: Time.current)
  end

  def mark_stale!
    update!(status: "stale", stale_at: Time.current)
  end

  def archive!
    update!(status: "archived")
  end

  def in_progress?
    status == "in_progress"
  end

  def completed?
    status == "completed"
  end

  def stale?
    return true if status == "stale"
    return false unless completed?

    completed_at.present? && completed_at < STALENESS_THRESHOLD.ago
  end

  def progress
    total = context_intake_responses.count
    answered = context_intake_responses.answered.count
    return { total: 0, answered: 0, percentage: 0 } if total.zero?

    { total: total, answered: answered, percentage: (answered * 100.0 / total).round }
  end

  def responses_by_section
    context_intake_responses.order(:section, :sequence).group_by(&:section)
  end

  def follow_up_generation_state
    metadata.to_h.fetch("follow_up_generation", {})
  end

  def follow_up_generation_pending?
    follow_up_generation_state["status"] == "pending"
  end

  def follow_up_generation_failed?
    follow_up_generation_state["status"] == "failed"
  end

  def follow_up_generation_blocking?
    follow_up_generation_state["blocking"] == true
  end

  def blocking_follow_up_generation_active?
    follow_up_generation_blocking? && follow_up_generation_pending?
  end

  def blocking_follow_up_generation_failed?
    follow_up_generation_blocking? && follow_up_generation_failed?
  end

  def clear_follow_up_generation!
    update!(metadata: metadata.to_h.except("follow_up_generation"))
  end
end
