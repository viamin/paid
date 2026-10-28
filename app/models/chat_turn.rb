# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :initiating_message_id, uniqueness: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ...time) }

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.where("chat_messages.id > ?", initiating_message_id).exists?
  end

  def expected_to_continue?
    metadata.fetch("expected_completion_at", nil).to_s.then { |value| value.present? && Time.iso8601(value) > Time.current }
  rescue ArgumentError
    false
  end

  def terminal?
    !status.in?(ACTIVE_STATUSES)
  end
end
