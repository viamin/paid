# frozen_string_literal: true

# Durable lifecycle for one user-initiated chat exchange. The user message is
# the recovery checkpoint: retries rebuild the transcript from that row rather
# than creating a second request.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :watchable, -> { where(status: %w[pending streaming]) }
  scope :stalled, -> { where(status: "stalled") }

  STATUSES.each do |value|
    define_method("#{value}?") { status == value }
  end

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def resumable?
    status == "stalled" && !awaiting_confirmation? && !side_effecting_tool_completed?
  end

  def side_effecting_tool_completed?
    chat_session.messages.where(role: "tool").joins(<<~SQL.squish).exists?
      INNER JOIN chat_messages tool_calls
        ON tool_calls.chat_session_id = chat_messages.chat_session_id
        AND tool_calls.tool_call_id = chat_messages.tool_call_id
        AND tool_calls.role = 'assistant'
        AND tool_calls.tool_status = 'approved'
    SQL
  end

  def record!(event, attributes = {})
    update!(attributes.merge(last_activity_at: Time.current))
    Rails.logger.info(message: "chat_turn.#{event}", chat_turn_id: id, chat_session_id: chat_session_id,
      status: status, classification: classification)
  end
end
