# frozen_string_literal: true

# A durable execution attempt for one user chat message. It deliberately does
# not infer success from streamed browser state: only an explicit terminal
# transition can complete a turn.
class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :state, inclusion: { in: STATES }
  validates :stream_message_id, presence: true, uniqueness: { scope: :chat_session_id }

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ..time) }

  def record_activity!(at: Time.current)
    update!(state: "streaming", last_activity_at: at)
  end

  def complete!(reason: "assistant_response")
    update!(state: "completed", completed_at: Time.current,
      last_activity_at: Time.current, metadata: metadata.merge("completion_reason" => reason))
  end

  def fail!(classification:)
    update!(state: "failed", completed_at: Time.current, last_activity_at: Time.current,
      failure_classification: classification)
  end

  def pending_confirmation?
    return false unless user_message

    chat_session.messages.pending_tool_confirmations.where("created_at >= ?", user_message.created_at).exists?
  end
end
