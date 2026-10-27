# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-RECOVERY-001
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_AFTER = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :state, inclusion: { in: STATES }
  validates :user_message_id, uniqueness: true

  scope :incomplete, -> { where(state: %w[pending streaming]) }
  scope :quiet_before, ->(time) { incomplete.where(last_activity_at: ...time) }

  def pending? = state == "pending"
  def streaming? = state == "streaming"
  def stalled? = state == "stalled"
end
