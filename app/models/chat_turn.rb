# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATES = %w[pending streaming].freeze
  TERMINAL_STATES = %w[completed failed stalled abandoned].freeze
  DEFAULT_STALL_THRESHOLD = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :assistant_message, class_name: "ChatMessage", optional: true

  validates :state, inclusion: { in: STATES }
  validates :stream_message_id, presence: true, uniqueness: true

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :stalled, -> { where(state: "stalled") }
  scope :inactive_since, ->(time) { active.where("last_activity_at < ?", time) }

  def self.stall_threshold
    Integer(ENV.fetch("CHAT_TURN_STALL_THRESHOLD", DEFAULT_STALL_THRESHOLD.to_i)).seconds
  rescue ArgumentError
    DEFAULT_STALL_THRESHOLD
  end

  def start!
    update!(state: "streaming", last_activity_at: Time.current) if state == "pending"
  end

  def checkpoint!(message)
    attributes = { last_activity_at: Time.current }
    attributes[:user_message] = message if message.role == "user"
    attributes[:assistant_message] = message if message.role == "assistant" && message.content.present?
    update!(attributes)
  end

  def complete!(message = nil)
    attributes = { state: "completed", completed_at: Time.current, last_activity_at: Time.current }
    attributes[:assistant_message] = message if message&.role == "assistant"
    update!(attributes)
  end

  def fail!(classification)
    self.class.where(id: id, state: ACTIVE_STATES).update_all(
      state: "failed", failure_classification: classification, completed_at: Time.current,
      last_activity_at: Time.current, updated_at: Time.current
    ).positive?
  end

  def stall!
    updated = self.class.where(id: id, state: ACTIVE_STATES).update_all(
      state: "stalled", stalled_at: Time.current, completed_at: Time.current, updated_at: Time.current
    )
    reload if updated.positive?
    updated.positive?
  end

  def stalled_notice?
    chat_session.messages.where("metadata ->> 'chat_turn_stalled_notice' = 'true'")
      .where("metadata ->> 'chat_turn_id' = ?", id.to_s).exists?
  end
end
