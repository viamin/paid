# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :actor, class_name: "User", optional: true
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: { scope: :chat_session_id }

  scope :unfinished, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(time) { unfinished.where(last_activity_at: ..time) }

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def stall_exempt?
    expires_at = metadata.fetch("stall_exempt_until", nil)
    expires_at.present? && Time.zone.parse(expires_at.to_s) > Time.current
  rescue ArgumentError
    false
  end
end
