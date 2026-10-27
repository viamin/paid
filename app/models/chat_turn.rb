# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where("activity_at < ?", time) }

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.where("id >= ?", initiating_message_id).exists?
  end

  def side_effecting_tool_completed?
    chat_session.messages.where("chat_messages.id >= ?", initiating_message_id)
      .where(role: "tool").joins("INNER JOIN chat_messages calls ON calls.tool_call_id = chat_messages.tool_call_id")
      .where("calls.tool_status = ?", "approved").exists?
  end
end
