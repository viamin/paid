# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-004
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  INCOMPLETE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :messages, class_name: "ChatMessage", dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :stalled_before, ->(time) { where(status: INCOMPLETE_STATUSES).where(last_activity_at: ..time) }

  def record_activity!
    update!(last_activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", terminal_at: Time.current, last_activity_at: Time.current)
  end

  def await_confirmation!
    update!(status: "awaiting_confirmation", terminal_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(classification: "application")
    update!(status: "failed", failure_classification: classification, terminal_at: Time.current, last_activity_at: Time.current)
  end

  def mark_stalled!(before:)
    with_lock do
      reload
      return false unless status.in?(INCOMPLETE_STATUSES)
      return false if last_activity_at > before

      update!(status: "stalled", failure_classification: "inactivity", stalled_at: Time.current, terminal_at: Time.current)
      chat_session.messages.create!(chat_turn: self, role: "system", content: stalled_notice_content, metadata: stalled_notice_metadata)
      true
    end
  end

  def request_recovery!
    with_lock do
      reload
      return false unless status == "stalled" && recovery_requested_at.nil?

      update!(recovery_requested_at: Time.current, recovery_attempts: recovery_attempts + 1)
      true
    end
  end

  private

  def stalled_notice_content
    confirmations = pending_confirmation_messages.count
    completed_tools = messages.where(role: "tool").count
    "This turn needs attention. #{completed_tools} tool result#{'s' unless completed_tools == 1} " \
      "were preserved, but no final assistant response was recorded. " \
      "#{confirmations} confirmation#{'s' unless confirmations == 1} still await#{confirmations == 1 ? 's' : ''} a decision. " \
      "Review the preserved activity before resuming; no action was replayed."
  end

  def stalled_notice_metadata
    {
      "stalled_turn_notice" => true,
      "chat_turn_id" => id,
      "completed_tool_count" => messages.where(role: "tool").count,
      "pending_confirmation_message_ids" => pending_confirmation_messages.pluck(:id)
    }
  end

  def pending_confirmation_messages
    messages.pending_tool_confirmations
  end
end
