# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_AFTER = 10.minutes

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage"

  validates :state, inclusion: { in: STATES }

  scope :stale_active, ->(now = Time.current) { where(state: %w[pending streaming]).where(last_activity_at: ..(now - STALL_AFTER)) }

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.where("id > ?", initiating_message_id).exists?
  end

  def start!
    # @spec CHAT-API-027
    update!(state: "streaming", last_activity_at: Time.current)
  end

  def complete!
    # @spec CHAT-API-027
    update!(state: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(error)
    update!(state: "failed", completed_at: Time.current, last_activity_at: Time.current, metadata: metadata.merge("error_class" => error.class.name))
  end
end
