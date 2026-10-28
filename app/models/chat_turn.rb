# frozen_string_literal: true

# @spec CHAT-TURN-001 CHAT-TURN-002
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  TERMINAL_STATUSES = %w[completed failed stalled abandoned].freeze
  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true
  scope :incomplete, -> { where(status: %w[pending streaming]) }
  def terminal? = status.in?(TERMINAL_STATUSES)
  def pending_confirmation? = chat_session.messages.pending_tool_confirmations.exists?
  def side_effecting_tools_completed? = chat_session.messages.where(role: "tool").where.not(tool_call_id: nil).exists?
end
