# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  TERMINAL_STATUSES = %w[completed failed abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :stale_streams, ->(before) { where(status: "streaming").where(last_activity_at: ..before) }

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def pending_confirmation?
    ChatMessage.pending_tool_confirmations.where(chat_session_id:).where("chat_messages.id > ?", user_message_id).exists?
  end

  def paused_for_rate_limit?
    chat_session.rate_limited_until.present?
  end

  def touch_activity!
    update!(last_activity_at: Time.current) unless terminal? || status == "stalled"
  end

  def transition_to!(next_status, classification: nil, data: {})
    update!(status: next_status, classification:, last_activity_at: Time.current, detected_at: detected_at_for(next_status), completed_at: completed_at_for(next_status))
    events.create!(event_type: next_status, data: data.compact)
  end

  def side_effecting_tools_completed?
    chat_session.messages.where("chat_messages.id > ?", user_message_id).where(role: "tool").joins(<<~SQL.squish).exists?
      INNER JOIN chat_messages tool_calls
        ON tool_calls.chat_session_id = chat_messages.chat_session_id
        AND tool_calls.tool_call_id = chat_messages.tool_call_id
        AND tool_calls.role = 'assistant'
        AND tool_calls.tool_status = 'approved'
    SQL
  end

  private

  def detected_at_for(next_status)
    next_status == "stalled" ? Time.current : detected_at
  end

  def completed_at_for(next_status)
    next_status.in?(TERMINAL_STATUSES) ? Time.current : completed_at
  end
end
