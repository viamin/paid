# frozen_string_literal: true

class AgentRunLog < ApplicationRecord
  LOG_TYPES = %w[stdout stderr system metric].freeze

  belongs_to :agent_run

  validates :log_type, presence: true, inclusion: { in: LOG_TYPES }
  validates :content, presence: true

  scope :by_type, ->(type) { where(log_type: type) }
  scope :stdout, -> { where(log_type: "stdout") }
  scope :stderr, -> { where(log_type: "stderr") }
  scope :system, -> { where(log_type: "system") }
  scope :metric, -> { where(log_type: "metric") }
  scope :recent, -> { order(created_at: :desc) }
  scope :chronological, -> { order(created_at: :asc) }
end
