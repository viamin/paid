# frozen_string_literal: true

class QualityPauseEvent < ApplicationRecord
  EVENT_TYPES = %w[paused resumed].freeze

  belongs_to :project
  belongs_to :agent_run, optional: true

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :composite_score,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
  validates :threshold,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true

  scope :pauses, -> { where(event_type: "paused") }
  scope :resumes, -> { where(event_type: "resumed") }
  scope :recent, -> { order(created_at: :desc) }
end
