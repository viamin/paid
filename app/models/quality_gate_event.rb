# frozen_string_literal: true

class QualityGateEvent < ApplicationRecord
  EVENT_TYPES = %w[trigger recovery].freeze

  belongs_to :project
  belongs_to :quality_threshold
  belongs_to :quality_metric

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :score_value, presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :threshold_value, presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  scope :triggers, -> { where(event_type: "trigger") }
  scope :recoveries, -> { where(event_type: "recovery") }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_project, ->(project_id) { where(project_id: project_id) }
end
