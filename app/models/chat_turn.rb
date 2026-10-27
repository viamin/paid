# frozen_string_literal: true

# Durable lifecycle evidence for one persisted user message. This intentionally
# records state server-side: browser streaming state cannot establish whether a
# turn completed after a disconnect or worker failure.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :streaming, -> { where(status: "streaming") }
  scope :stale, ->(at = Time.current) { streaming.where(last_activity_at: ..(at - STALL_THRESHOLD)) }

  STATUSES.each do |lifecycle_status|
    define_method("#{lifecycle_status}?") { status == lifecycle_status }
  end

  def pending_confirmation?
    pending?
  end

  def self.start!(chat_session:, user_message:)
    create!(chat_session:, user_message:, status: "streaming", last_activity_at: Time.current)
  end

  # @spec CHAT-TURN-RECOVERY-001
  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def await_confirmation!
    update!(status: "pending", last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
  end

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  def stall!
    with_lock do
      reload
      return false unless streaming?

      update!(status: "stalled", detected_at: Time.current, failure_classification: "inactivity")
      chat_session.messages.create!(
        role: "system",
        content: stalled_notice_content,
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => id,
          "pending_confirmation_ids" => pending_confirmation_ids
        }
      )
    end

    true
  end

  private

  def stalled_notice_content
    "This chat turn stopped before Paid recorded a final assistant response. " \
      "Any messages and tool results above were preserved, but completion is unknown. " \
      "Review any pending confirmations, then send a new message to retry deliberately; " \
      "Paid will not automatically replay this turn."
  end

  def pending_confirmation_ids
    chat_session.messages.pending_tool_confirmations.order(:id).pluck(:id)
  end
end
