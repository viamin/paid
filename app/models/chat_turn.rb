# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATES = %w[pending streaming].freeze
  STALL_THRESHOLD = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :stream_id, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES }

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ...time) }

  def start! = update!(state: "streaming", last_activity_at: Time.current)
  def touch_activity! = update!(last_activity_at: Time.current) if state.in?(ACTIVE_STATES)
  def complete! = update!(state: "completed", completed_at: Time.current, last_activity_at: Time.current)
  def fail!(classification:) = update!(state: "failed", failure_classification: classification, completed_at: Time.current, last_activity_at: Time.current)
  def stall! = update!(state: "stalled", detected_at: Time.current, last_activity_at: Time.current)
end
