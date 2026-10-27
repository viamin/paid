# frozen_string_literal: true

# Durable server-side boundary for one submitted chat message. Browser stream
# state is intentionally not authoritative: a worker can die after persisting
# partial tool evidence, so recovery and the transcript use this record.
class ChatTurn < ApplicationRecord
  # @spec CHAT-API-027
  STATES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :state, inclusion: { in: STATES }
  validates :stream_message_id, uniqueness: true
  validates :user_message_id, uniqueness: true

  scope :active, -> { where(state: %w[pending streaming]) }
  scope :stale, -> { active.where(last_activity_at: ...STALL_THRESHOLD.ago) }

  def touch_activity!
    update!(last_activity_at: Time.current)
  end

  def streaming!
    update!(state: "streaming", last_activity_at: Time.current)
  end

  def complete!
    update!(state: "completed", last_activity_at: Time.current)
  end

  def awaiting_confirmation!
    update!(state: "awaiting_confirmation", last_activity_at: Time.current)
  end

  def fail!
    update!(state: "failed", last_activity_at: Time.current)
  end

  def stallable?
    active? && last_activity_at < STALL_THRESHOLD.ago && !chat_session.messages.pending_tool_confirmations.exists?
  end

  def active?
    state.in?(%w[pending streaming])
  end

  def stall!
    with_lock do
      reload
      return false unless stallable?

      update!(state: "stalled", stalled_at: Time.current, last_activity_at: Time.current)
      chat_session.messages.create!(role: "system", content: stalled_notice_content, metadata: stalled_notice_metadata)
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: id, chat_session_id: chat_session_id,
        user_message_id: user_message_id)
      true
    end
  end

  private

  def stalled_notice_content
    "This response stopped before a final answer was saved. Any completed tool activity is preserved above; " \
      "the remaining response is unknown. Review completed actions before retrying so side effects are not repeated."
  end

  def stalled_notice_metadata
    { "chat_turn_stalled" => true, "chat_turn_id" => id, "stream_message_id" => stream_message_id }
  end
end
