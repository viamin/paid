# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-RECOVERY-001, CHAT-TURN-RECOVERY-003
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  DEFAULT_STALL_TIMEOUT = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, presence: true

  scope :streaming, -> { where(status: "streaming") }
  scope :stale_before, ->(time) { streaming.where("last_activity_at <= ?", time) }

  def self.stall_timeout
    ENV.fetch("CHAT_TURN_STALL_TIMEOUT_SECONDS", DEFAULT_STALL_TIMEOUT.to_i).to_i.seconds
  end

  def terminal?
    status.in?(%w[completed failed abandoned])
  end

  def recovery_safe?
    user_message.present? && !side_effecting_tool_completed?
  end
end
