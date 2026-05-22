# frozen_string_literal: true

class ProjectConventionRecommendation < ApplicationRecord
  ACTION_TYPES = %w[apply_in_paid open_pr apply_github_side].freeze
  STATUSES = %w[pending applied dismissed].freeze

  belongs_to :project
  belongs_to :dismissed_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true

  validates :convention_key, presence: true, length: { maximum: 100 }
  validates :action_type, presence: true, inclusion: { in: ACTION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :title, presence: true, length: { maximum: 255 }
  validates :description, presence: true
  validates :dismissal_reason, presence: true, if: :dismissed?

  scope :pending, -> { where(status: "pending") }
  scope :resolved, -> { where.not(status: "pending") }
  scope :by_recency, -> { order(generated_at: :desc, created_at: :desc) }

  def dismiss!(dismissed_by:, reason:)
    update!(
      status: "dismissed",
      dismissed_by: dismissed_by,
      dismissed_at: Time.current,
      dismissal_reason: reason
    )
  end

  def apply!(applied_by:)
    update!(
      status: "applied",
      applied_by: applied_by,
      applied_at: Time.current
    )
  end

  def pending?
    status == "pending"
  end

  def dismissed?
    status == "dismissed"
  end

  def applied?
    status == "applied"
  end

  def resolved?
    status.in?(%w[applied dismissed])
  end
end
