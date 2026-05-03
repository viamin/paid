# frozen_string_literal: true

class KnowledgeRecommendation < ApplicationRecord
  belongs_to :project

  RECOMMENDATION_TYPES = %w[add_collector remove_collector improve_collector knowledge_gap].freeze
  PRIORITIES = %w[low medium high critical].freeze
  STATUSES = %w[pending accepted dismissed implemented].freeze

  validates :recommendation_type, presence: true, inclusion: { in: RECOMMENDATION_TYPES }
  validates :priority, presence: true, inclusion: { in: PRIORITIES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :description, presence: true
  validates :dismissal_reason, presence: true, if: :dismissed?

  scope :pending, -> { where(status: "pending") }
  scope :accepted, -> { where(status: "accepted") }
  scope :by_priority, -> { in_order_of(:priority, PRIORITIES.reverse) }

  def dismiss!(reason:)
    update!(status: "dismissed", dismissed_at: Time.current, dismissal_reason: reason)
  end

  def accept!
    update!(status: "accepted")
  end

  private

  def dismissed?
    status == "dismissed"
  end
end
