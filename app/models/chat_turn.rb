# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = Integer(ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 10.minutes.to_i)).seconds

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :state, inclusion: { in: STATES }
  validates :stream_message_id, presence: true, uniqueness: true

  scope :overdue, ->(at = Time.current) { where(state: %w[pending streaming]).where("checkpointed_at < ?", at) }

  def stalled?
    state == "stalled"
  end

  def terminal?
    state.in?(%w[completed failed stalled abandoned])
  end

  def checkpoint!(user_message: nil)
    update!(checkpointed_at: Time.current, user_message: user_message || self.user_message)
  end

  def complete!
    update!(state: "completed", checkpointed_at: Time.current, terminal_at: Time.current)
  end

  def fail!(classification:)
    update!(state: "failed", failure_classification: classification, checkpointed_at: Time.current, terminal_at: Time.current)
  end
end
